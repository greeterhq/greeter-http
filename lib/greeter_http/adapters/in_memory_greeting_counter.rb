# frozen_string_literal: true

require 'greeter_http/ports/greeting_counter'

module GreeterHttp
  module Adapters
    # In-memory GreetingCounter: the reference implementation used by
    # application and acceptance tests. Thread-safe atomic increments, per-guest
    # counters, and idempotency keyed on (key -> fingerprint, count_snapshot)
    # with a bounded retention window.
    class InMemoryGreetingCounter < Ports::GreetingCounter
      DEFAULT_TTL_SECONDS = 86_400

      # @param clock [#now] source of the current time (for TTL). Defaults to a
      #   wall-clock reader; tests inject a controllable clock.
      # @param ttl_seconds [Integer] retention window for idempotency keys.
      def initialize(clock: WallClock.new, ttl_seconds: DEFAULT_TTL_SECONDS)
        super()
        @clock = clock
        @ttl_seconds = ttl_seconds
        @counts = Hash.new(0)   # guest_key => count
        @dedupe = {}            # idempotency_key => { fingerprint:, count:, expires_at: }
        @mutex = Mutex.new
      end

      def increment(guest:, idempotency_key:, fingerprint:, synthetic: false)
        validate_arguments!(idempotency_key: idempotency_key, fingerprint: fingerprint)
        # Synthetic (monitoring) traffic counts under an isolated key space so
        # it never inflates real per-guest counts.
        guest_key = synthetic ? "synthetic##{guest}" : guest.to_s

        @mutex.synchronize do
          purge_expired

          existing = @dedupe[idempotency_key]
          if existing
            unless existing[:fingerprint] == fingerprint
              raise KeyReused, 'idempotency key already used for a different request'
            end

            return Result.new(count: existing[:count], replayed: true)
          end

          new_count = (@counts[guest_key] += 1)
          @dedupe[idempotency_key] = {
            fingerprint: fingerprint,
            count: new_count,
            expires_at: now_epoch + @ttl_seconds
          }
          Result.new(count: new_count, replayed: false)
        end
      end

      private

      def now_epoch
        @clock.now.to_i
      end

      def purge_expired
        now = now_epoch
        @dedupe.delete_if { |_key, rec| rec[:expires_at] <= now }
      end

      # Minimal wall clock used when no clock is injected.
      class WallClock
        def now
          Time.now.utc
        end
      end
    end
  end
end
