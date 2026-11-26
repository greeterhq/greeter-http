# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'securerandom'

module GreeterHttp
  module Perf
    # Ruby-thread load generator for the deployed endpoint. VUS threads each
    # issue POST /greetings in a loop for DURATION_S, recording per-request
    # latency. The very first successful request (across all VUs) is captured
    # separately as the client-observed cold start and excluded from the
    # steady-state percentiles, so a Lambda cold start never skews the p95 gate.
    #
    # Each request targets a DISTINCT guest ("perf guest <vu>-<n>") so writes
    # spread across DynamoDB partitions, measuring real throughput rather than
    # single-item write contention. Hammering one guest would instead serialize
    # every VU on one counter item (the hot-partition case), where the
    # optimistic-lock transaction sheds load as 503s under heavy concurrency.
    #
    # The generator is RATE-PACED to the service's configured capacity (the
    # HttpApi stage throttles at RouteThrottleRate req/s). Each VU paces itself
    # to rate/vus req/s with think-time, so the aggregate stays at or just under
    # the rated limit. This measures latency under sustained rated load rather
    # than overrunning the throttle. An accidental overrun surfaces as HTTP 429,
    # which is accounted SEPARATELY as "throttled" (expected backpressure), not
    # as a hard failure — only 5xx, connection errors, and non-429 4xx fail.
    #
    # Every request sends X-Greeter-Synthetic: true, so load traffic stays out of real guest counts.
    #
    # Only Ruby stdlib is used (net/http) — no k6 binary required. A k6 script
    # would be a drop-in alternative if preferred in CI.
    module Load
      module_function

      # rate: target aggregate requests/second across all VUs (nil => unpaced).
      def run(base_url:, vus:, duration_s:, rate: nil)
        uri = URI.join("#{base_url.chomp('/')}/", 'greetings')
        deadline = monotonic + duration_s
        # Per-VU minimum seconds between request starts to hold the aggregate at
        # `rate`. nil/zero rate => unpaced (0 interval).
        interval = rate&.positive? ? vus.to_f / rate : 0.0

        latencies = Array.new(vus) { [] } # per-thread, lock-free
        oks = Array.new(vus, 0)
        throttled = Array.new(vus, 0) # per-thread HTTP 429 tally (backpressure)
        reasons = Array.new(vus) { Hash.new(0) } # per-thread hard-failure tally
        cold_start_ms = nil
        cold_mutex = Mutex.new

        threads = Array.new(vus) do |i|
          Thread.new do
            http = new_connection(uri)
            n = 0
            while monotonic < deadline
              n += 1
              slot = monotonic
              guest = "perf guest #{i}-#{n}" # distinct guest => distinct partition
              reason, elapsed_ms = timed_attempt(http, uri, guest)

              is_cold_start = cold_mutex.synchronize do
                if reason == :ok && cold_start_ms.nil?
                  cold_start_ms = elapsed_ms
                  true
                else
                  false
                end
              end

              tally(reason, i, oks, throttled, reasons)
              # Steady state excludes the one cold-start sample.
              latencies[i] << elapsed_ms if reason == :ok && !is_cold_start

              pace(slot, interval)
            end
            http.finish if http.started?
          end
        end
        threads.each(&:join)

        summarize(oks, throttled, reasons, latencies, cold_start_ms)
      end

      def new_connection(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.keep_alive_timeout = 10
        http.start
        http
      end

      def timed_attempt(http, uri, guest)
        t0 = monotonic
        reason = attempt(http, uri, guest)
        [reason, (monotonic - t0) * 1000.0]
      end

      # Tally a request outcome into the per-thread counters:
      #   :ok        => success, :throttled => HTTP 429 (backpressure),
      #   anything else => a hard failure, keyed by its reason symbol.
      def tally(reason, idx, oks, throttled, reasons)
        case reason
        when :ok then oks[idx] += 1
        when :throttled then throttled[idx] += 1
        else reasons[idx][reason] += 1
        end
      end

      # Sleep the remainder of this VU's per-request time slot so the aggregate
      # request rate stays at the target. No-op when unpaced or already over.
      def pace(slot_start, interval)
        return if interval <= 0.0

        remaining = interval - (monotonic - slot_start)
        sleep(remaining) if remaining.positive?
      end

      def summarize(oks, throttled, reasons, latencies, cold_start_ms)
        steady = latencies.flatten.sort
        failure_reasons = merge_reasons(reasons)
        {
          total: oks.sum + throttled.sum + failure_reasons.values.sum,
          ok: oks.sum,
          throttled: throttled.sum,
          failed: failure_reasons.values.sum,
          failure_reasons: failure_reasons,
          cold_start_ms: cold_start_ms || 0.0,
          p50_ms: pct(steady, 0.50),
          p95_ms: pct(steady, 0.95),
          p99_ms: pct(steady, 0.99)
        }
      end

      # Combine the per-thread reason tallies into one { reason => count } hash,
      # sorted most-frequent first so the dominant failure mode is obvious.
      def merge_reasons(per_thread)
        totals = Hash.new(0)
        per_thread.each { |h| h.each { |reason, count| totals[reason] += count } }
        totals.sort_by { |_reason, count| -count }.to_h
      end

      # Returns :ok on success, :throttled on HTTP 429 (expected backpressure),
      # or a symbol naming the hard-failure mode (an HTTP status like :http_503,
      # or a client-side exception class like :"Errno::ECONNRESET") so the
      # harness reports WHY requests failed instead of a bare count that hides
      # whether the server throttled, erred, or the client gave up.
      def attempt(http, uri, guest)
        req = Net::HTTP::Post.new(uri)
        req['Content-Type'] = 'application/json'
        req['Idempotency-Key'] = SecureRandom.uuid
        req['X-Greeter-Synthetic'] = 'true'
        req.body = JSON.generate('name' => guest)
        resp = http.request(req)
        return :ok if %w[200 201].include?(resp.code) # 201 created / 200 replay

        return :throttled if resp.code == '429' # rate-limited (not a failure) # rate-limited (not a failure)

        :"http_#{resp.code}"
      rescue StandardError => e
        :"#{e.class}"
      end

      def pct(sorted, p)
        return 0.0 if sorted.empty?

        idx = (sorted.length * p).ceil - 1
        sorted[idx.clamp(0, sorted.length - 1)]
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
