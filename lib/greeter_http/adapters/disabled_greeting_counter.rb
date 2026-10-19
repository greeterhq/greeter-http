# frozen_string_literal: true

require 'greeter_http/ports/greeting_counter'

module GreeterHttp
  module Adapters
    # Null-object GreetingCounter used when GREETER_COUNTER_ENABLED=false.
    #
    # "Greet but don't count": the service still greets the guest successfully,
    # but no datastore is touched and the count is reported as not tracked
    # (nil -> JSON null in the response). This is an operational kill switch for
    # the persistence layer that degrades gracefully without a redeploy — flip
    # the env var to stop all DynamoDB access instantly, keeping greetings up.
    #
    # Every call is treated as a fresh (non-replayed) greeting: with no store
    # there is no idempotency state to consult, which is acceptable because no
    # count is being produced to double.
    class DisabledGreetingCounter < Ports::GreetingCounter
      def increment(guest:, idempotency_key:, fingerprint:, synthetic: false)
        validate_arguments!(idempotency_key: idempotency_key, fingerprint: fingerprint)
        Result.new(count: nil, replayed: false)
      end
    end
  end
end
