# frozen_string_literal: true

require 'digest'
require 'greeter_http/application/greeted_guest'

module GreeterHttp
  module Application
    # Composes the greeter-core use case with a local GreetingCounter port.
    # Greets the guest (core), then records the greeting and returns the running
    # count. Core is composed, never reopened or subclassed.
    class GreetAndCount
      # @param greeting_service [#greet] Greeter::Core::Domain::GreetingService
      # @param greeting_counter [Ports::GreetingCounter]
      def initialize(greeting_service:, greeting_counter:)
        @greeting_service = greeting_service
        @greeting_counter = greeting_counter
      end

      # @param synthetic [Boolean] when true, the counter records under an
      #   isolated key space so monitoring traffic never affects real counts.
      # @raise [Greeter::Core::Domain::InvalidGuestName] propagated from core;
      #   the counter is NOT touched when the name is invalid.
      def call(raw_name:, idempotency_key:, synthetic: false)
        greeting = @greeting_service.greet(raw_name)
        guest_name = greeting.guest_name

        result = @greeting_counter.increment(
          guest: guest_name.display,
          idempotency_key: idempotency_key,
          fingerprint: fingerprint_for(guest_name),
          synthetic: synthetic
        )

        GreetedGuest.new(
          guest_name: guest_name.display,
          count: result.count,
          greeted_at: greeting.greeted_at,
          replayed: result.replayed?
        )
      end

      private

      # Fingerprint over the normalized request (the titlecased display name),
      # so names differing only by case/whitespace are the same request.
      def fingerprint_for(guest_name)
        "sha256:#{Digest::SHA256.hexdigest(guest_name.display)}"
      end
    end
  end
end
