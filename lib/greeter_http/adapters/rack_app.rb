# frozen_string_literal: true

require 'json'
require 'digest'
require 'rack'
require 'greeter/core'
require 'greeter_http/ports/greeting_counter'

module GreeterHttp
  module Adapters
    # Rack application owning HTTP concerns: routing (POST /greetings), JSON
    # parsing, Idempotency-Key extraction, response presentation, and mapping
    # domain/port errors to HTTP status. Business logic is delegated to the
    # injected GreetAndCount use case.
    #
    # Emits one structured JSON log line per request (to stderr -> CloudWatch)
    # with a correlation id, duration, outcome, the composed greeter-core
    # version, and a SHA-256 hash of the guest name (never the name itself).
    class RackApp
      JSON_HEADERS = { 'content-type' => 'application/json' }.freeze

      # Hard cap on the request body. The only valid payload is a tiny JSON
      # object ({"name": "..."}) whose name is bounded by the core at 64 chars,
      # so a few KB is generous. Caps unbounded reads so a malicious client
      # cannot exhaust memory with a giant body before validation runs.
      MAX_BODY_BYTES = 8 * 1024

      # HTML / template / escape metacharacters rejected at the HTTP boundary
      # BEFORE the name reaches the core. A greeting service must echo the name
      # back ("Hello, <name>!"), so these characters have no place in a real
      # name and their only purpose in a request is a reflected-XSS or
      # template-injection probe (<script>, "><img>, {{7*7}}). The response is
      # already JSON-encoded (so such input is inert in a JSON client), but we
      # reject it outright as defense-in-depth for any consumer that mishandles
      # the body. Apostrophes and hyphens are deliberately NOT included so real
      # names like O'Brien and Jean-Luc are accepted. The core gem is composed,
      # never modified, so this guard lives here at the adapter boundary.
      FORBIDDEN_NAME_CHARS = /[<>{}\\]/

      # Request-rejection errors raised on the happy path and mapped to HTTP by
      # #map_error. Defined before ERROR_MAP, which references them.
      class MalformedRequest < StandardError; end
      class PayloadTooLarge < StandardError; end
      class DisallowedName < StandardError; end
      class MissingIdempotencyKey < StandardError; end

      # Expected-error -> [http_status, code/outcome, client_message]. The code
      # is both the JSON error code and the log `outcome`. Anything not listed
      # here is a storage/unexpected error, handled by #map_unexpected.
      ERROR_MAP = {
        MissingIdempotencyKey => [400, 'missing_idempotency_key', 'Idempotency-Key header is required.'],
        PayloadTooLarge => [413, 'payload_too_large', 'Request body is too large.'],
        MalformedRequest => [400, 'malformed_request', 'Request body is not valid JSON.'],
        DisallowedName => [422, 'invalid_name', 'Name contains disallowed characters.'],
        Greeter::Core::Domain::InvalidGuestName => [422, 'invalid_name', 'Invalid name.'],
        Ports::GreetingCounter::KeyReused =>
          [409, 'idempotency_key_reused', 'This Idempotency-Key was already used for a different request.']
      }.freeze

      # @param use_case [#call] GreetAndCount
      #   (keyword call: raw_name:, idempotency_key:, synthetic:)
      # @param presenter [#present] a GreetingPresenter adapter
      # @param logger [#info] structured logger; defaults to a stderr JSON logger
      # @param monotonic [#call] returns a monotonic seconds Float; injectable
      #   for deterministic duration in tests
      def initialize(use_case:, presenter:, max_body_bytes: MAX_BODY_BYTES,
                     logger: StderrJsonLogger.new, monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @use_case = use_case
        @presenter = presenter
        @max_body_bytes = max_body_bytes
        @logger = logger
        @monotonic = monotonic
      end

      def call(env)
        started = @monotonic.call
        ctx = { outcome: nil, name_hash: nil, synthetic: synthetic?(env), trace_id: trace_id(env) }
        request = Rack::Request.new(env)

        status, headers, body =
          if greetings_post?(request)
            handle_greeting(request, ctx)
          else
            ctx[:outcome] = 'not_found'
            error(404, 'not_found', 'Not found.')
          end

        emit_log(ctx, status, started)
        [status, headers, body]
      end

      private

      def greetings_post?(request)
        request.post? && request.path_info == '/greetings'
      end

      def handle_greeting(request, ctx)
        greet(request, ctx)
      rescue StandardError => e
        map_error(e, ctx)
      end

      # The happy path: validate, greet, present. Any failure raises and is
      # mapped to an HTTP response by #handle_error.
      def greet(request, ctx)
        key = idempotency_key(request)
        raise MissingIdempotencyKey if key.nil? || key.empty?

        name = parse_name(request)
        ctx[:name_hash] = hash_name(name)
        reject_hostile_name!(name)

        result = @use_case.call(raw_name: name, idempotency_key: key, synthetic: ctx[:synthetic])
        ctx[:outcome] = result.replayed? ? 'replayed' : 'created'
        success(result)
      end

      # Map a raised error to (status, code, message) + the log outcome. The
      # expected 4xx cases come from a static table; storage/unexpected errors
      # (handled last) answer 503 when transient else 500, and never leak.
      def map_error(err, ctx)
        mapping = ERROR_MAP[err.class]
        return map_unexpected(err, ctx) unless mapping

        status, code, message = mapping
        ctx[:outcome] = code
        # InvalidGuestName carries a safe, static message from the core.
        message = err.message if err.is_a?(Greeter::Core::Domain::InvalidGuestName)
        error(status, code, message)
      end

      # Storage/unexpected errors: 503 (retryable) for a transient SDK error,
      # else 500. The cause is recorded for the log but never sent to the client.
      def map_unexpected(err, ctx)
        ctx[:error] = "#{err.class}: #{err.message}"
        if err.is_a?(Ports::GreetingCounter::Unavailable) || transient_service_error?(err)
          ctx[:outcome] = 'unavailable'
          return unavailable
        end
        ctx[:outcome] = 'internal_error'
        error(500, 'internal_error', 'An unexpected error occurred.')
      end

      def unavailable
        error(503, 'temporarily_unavailable', 'Please retry.', extra_headers: { 'retry-after' => '1' })
      end

      # SHA-256 of the raw name, so the same guest is correlatable in logs
      # without ever logging the name itself. Empty name => nil (nothing to
      # hash), so a missing-name request does not log a hash of "".
      def hash_name(name)
        return nil if name.nil? || name.empty?

        "sha256:#{Digest::SHA256.hexdigest(name)}"
      end

      # Correlation id for the request: AWS's X-Ray trace header when present,
      # falling back to the API Gateway request id, else nil.
      def trace_id(env)
        env['HTTP_X_AMZN_TRACE_ID'] || env['HTTP_X_AMZN_REQUESTID']
      end

      # True when the caller marked this as synthetic monitoring traffic.
      def synthetic?(env)
        env['HTTP_X_GREETER_SYNTHETIC'].to_s.strip.downcase == 'true'
      end

      # Emit the one-per-request structured log line.
      def emit_log(ctx, status, started)
        duration_ms = ((@monotonic.call - started) * 1000.0).round(2)
        entry = {
          'outcome' => ctx[:outcome],
          'status' => status,
          'duration_ms' => duration_ms,
          'synthetic' => ctx[:synthetic],
          'correlation_id' => ctx[:trace_id],
          'name_hash' => ctx[:name_hash],
          'greeter_core_version' => Greeter::Core::VERSION
        }
        entry['error'] = ctx[:error] if ctx[:error]
        @logger.info(entry)
      end

      # Matches any `Aws::<Service>::Errors::ServiceError` by ancestry name.
      def transient_service_error?(error)
        error.class.ancestors.any? do |ancestor|
          ancestor.name =~ /\AAws::\w+::Errors::ServiceError\z/
        end
      end

      # Reject names carrying HTML/template/escape metacharacters at the
      # boundary, before the core or the counter ever see them.
      def reject_hostile_name!(name)
        raise DisallowedName if name.match?(FORBIDDEN_NAME_CHARS)
      end

      def idempotency_key(request)
        request.get_header('HTTP_IDEMPOTENCY_KEY')
      end

      def parse_name(request)
        body = read_capped_body(request)
        parsed = JSON.parse(body.empty? ? '{}' : body)
        raise MalformedRequest unless parsed.is_a?(Hash)

        parsed['name'].to_s
      rescue JSON::ParserError
        raise MalformedRequest
      end

      # Read the body with a hard byte cap. Checks the declared CONTENT_LENGTH
      # first (cheap reject), then reads at most max+1 bytes so a client that
      # lies about or omits Content-Length still cannot stream an unbounded body
      # into memory.
      def read_capped_body(request)
        declared = request.content_length.to_i
        raise PayloadTooLarge if declared > @max_body_bytes

        return '' unless request.body

        body = request.body.read(@max_body_bytes + 1).to_s
        raise PayloadTooLarge if body.bytesize > @max_body_bytes

        body
      end

      def success(result)
        status = result.replayed? ? 200 : 201
        body = @presenter.present_count(
          guest_name: result.guest_name,
          count: result.count,
          greeted_at: result.greeted_at
        )
        [status, JSON_HEADERS.dup, [JSON.generate(body)]]
      end

      def error(status, code, message, extra_headers: {})
        [status, JSON_HEADERS.merge(extra_headers), [JSON.generate(error: code, message: message)]]
      end

      # Default structured logger: one compact JSON object per line on stderr,
      # which the Lambda runtime forwards to CloudWatch. A "service" field tags
      # every line so greeter-http entries are filterable. Tests inject a
      # capturing logger instead.
      class StderrJsonLogger
        def info(fields)
          warn JSON.generate({ 'service' => 'greeter-http' }.merge(fields))
        end
      end
    end
  end
end
