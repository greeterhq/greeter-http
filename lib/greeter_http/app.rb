# frozen_string_literal: true

require 'greeter/core'
require 'aws-sdk-dynamodb'

require 'greeter_http/application/greet_and_count'
require 'greeter_http/adapters/in_memory_greeting_counter'
require 'greeter_http/adapters/dynamodb_greeting_counter'
require 'greeter_http/adapters/disabled_greeting_counter'
require 'greeter_http/adapters/system_clock'
require 'greeter_http/adapters/json_presenter'
require 'greeter_http/adapters/rack_app'
require 'greeter_http/adapters/lambda_handler'

module GreeterHttp
  # The ONLY composition root. This is the single place allowed to name
  # concrete adapter classes; everything else depends on ports.
  module App
    DEFAULT_TTL_SECONDS = 86_400

    module_function

    # Build the Rack application.
    #
    # @param greeting_counter [Ports::GreetingCounter, nil] injected counter.
    #   When nil, a DynamoDB-backed counter is constructed from the environment
    #   — this is the low-level composer's fallback. Prefer build_handler /
    #   build_from_env (which honor GREETER_BACKEND) over relying on this.
    # @param clock [#now] clock port; defaults to the system clock.
    def build(greeting_counter: nil, clock: Adapters::SystemClock.new)
      counter = greeting_counter || dynamodb_counter(clock)
      service = Greeter::Core::Domain::GreetingService.new(clock: clock)
      use_case = Application::GreetAndCount.new(
        greeting_service: service,
        greeting_counter: counter
      )
      Adapters::RackApp.new(use_case: use_case, presenter: Adapters::JsonPresenter.new)
    end

    # Build the Lambda handler wrapping the Rack app (production entry point).
    #
    # When no counter is injected (the deployed case), the backend is chosen by
    # GREETER_BACKEND exactly as the local server does — the datastore is NOT
    # hardcoded to DynamoDB. The default when GREETER_BACKEND is unset differs
    # by entry point: Lambda defaults to 'dynamodb' (a serverless function needs
    # durable, shared state), while config.ru defaults to 'memory' (zero-setup
    # local dev). Set GREETER_BACKEND to swap stores in either runtime.
    def build_handler(greeting_counter: nil, clock: Adapters::SystemClock.new)
      counter = greeting_counter || counter_from_env(default: 'dynamodb', clock: clock)
      Adapters::LambdaHandler.new(app: build(greeting_counter: counter, clock: clock))
    end

    # Build the Rack app choosing a counter backend from the environment. Used
    # by config.ru for local development; defaults to the in-memory store.
    def build_from_env(clock: Adapters::SystemClock.new)
      build(greeting_counter: counter_from_env(default: 'memory', clock: clock), clock: clock)
    end

    # The single place that maps GREETER_BACKEND to a concrete GreetingCounter
    # adapter. Add a new datastore here (e.g. 'postgres', 'redis') and it is
    # immediately selectable from both entry points. `default` is used when
    # GREETER_BACKEND is unset, so each entry point keeps its own sensible
    # default while sharing one selection mechanism.
    #
    # @return [Ports::GreetingCounter]
    def counter_from_env(default:, clock: Adapters::SystemClock.new)
      # Operational kill switch: GREETER_COUNTER_ENABLED=false disables the
      # datastore entirely (no DynamoDB access) without a redeploy. The service
      # still greets; the count is reported as not tracked. Takes precedence
      # over the backend selection below.
      return Adapters::DisabledGreetingCounter.new unless counter_enabled?

      backend = ENV.fetch('GREETER_BACKEND', default)
      case backend
      when 'memory'
        Adapters::InMemoryGreetingCounter.new
      when 'dynamodb'
        dynamodb_counter(clock)
      else
        raise ArgumentError,
              "unknown GREETER_BACKEND=#{backend.inspect} (expected one of: memory, dynamodb)"
      end
    end

    # The counter is ON unless GREETER_COUNTER_ENABLED is explicitly a falsey
    # string ("false"/"0"/"no"/"off", case-insensitive). Default-on so an unset
    # variable keeps the normal behaviour.
    def counter_enabled?
      raw = ENV.fetch('GREETER_COUNTER_ENABLED', 'true').to_s.strip.downcase
      !%w[false 0 no off].include?(raw)
    end

    def dynamodb_counter(clock)
      Adapters::DynamoDbGreetingCounter.new(
        client: dynamodb_client,
        table_name: ENV.fetch('GREETER_TABLE_NAME'),
        ttl_seconds: Integer(ENV.fetch('GREETER_IDEMPOTENCY_TTL_SECONDS', DEFAULT_TTL_SECONDS)),
        clock: clock
      )
    end

    # A human-readable description of the backend THAT WILL BE SELECTED for the
    # given default, for a startup banner. Reads GREETER_BACKEND exactly as
    # counter_from_env does, so the banner reports the real choice rather than a
    # hardcoded guess; the table name is appended only when dynamodb is in use.
    # Reports (not set) rather than raising if GREETER_TABLE_NAME is missing, so
    # a diagnostic banner never breaks startup.
    def startup_backend_description(default:)
      return 'backend=disabled (GREETER_COUNTER_ENABLED=false; greet-but-don\'t-count)' unless counter_enabled?

      backend = ENV.fetch('GREETER_BACKEND', default)
      return "backend=#{backend}" unless backend == 'dynamodb'

      "backend=dynamodb table=#{ENV.fetch('GREETER_TABLE_NAME', '(not set)')}"
    end

    # Honor an optional endpoint override so the function can run against a
    # local DynamoDB (e.g. DynamoDB Local via `sam local`). In AWS the variable
    # is unset and the SDK resolves the real regional endpoint and the task's
    # IAM credentials. For a local endpoint we also pass static dummy
    # credentials so DynamoDB Local accepts the request regardless of any
    # placeholder credentials the local runtime injected.
    def dynamodb_client
      endpoint = ENV.fetch('GREETER_DYNAMODB_ENDPOINT', nil)
      return Aws::DynamoDB::Client.new if endpoint.nil? || endpoint.empty?

      # DynamoDB Local accepts any credentials but rejects a session token it
      # cannot validate. Local runtimes (e.g. `sam local`) inject a placeholder
      # AWS_SESSION_TOKEN that the SDK would otherwise attach to the request, so
      # drop it on this local-only path before building the client.
      ENV.delete('AWS_SESSION_TOKEN')
      Aws::DynamoDB::Client.new(
        endpoint: endpoint,
        region: ENV.fetch('AWS_REGION', 'eu-west-1'),
        credentials: Aws::Credentials.new('local', 'local')
      )
    end
  end
end
