# frozen_string_literal: true

module GreeterHttp
  module Ports
    # Abstract port: records a greeting for a guest and returns the running
    # count, with idempotency keyed on a client-supplied key + request
    # fingerprint. Concrete implementations live in adapters/.
    class GreetingCounter
      # Raised when a known idempotency key is reused with a different request
      # fingerprint (same key, different content).
      class KeyReused < StandardError; end

      # Raised when the backing store fails transiently (throttling, timeout)
      # and the caller may retry.
      class Unavailable < StandardError; end

      # Result of an increment: the (post-increment) count and whether this was
      # a replay of a previously recorded request.
      Result = Struct.new(:count, :replayed, keyword_init: true) do
        def replayed?
          replayed
        end
      end

      # @param guest [#to_s] the normalized guest identity (GuestName)
      # @param idempotency_key [String]
      # @param fingerprint [String] hash of the normalized request
      # @param synthetic [Boolean] when true, record under an isolated
      #   ("synthetic#") key space so monitoring traffic never mixes with real
      #   per-guest counts.
      # @return [Result]
      def increment(guest:, idempotency_key:, fingerprint:, synthetic: false)
        raise NotImplementedError, "#{self.class}#increment is not implemented"
      end

      private

      # Guards the required string arguments. A nil/empty fingerprint (or key)
      # is a programming error — the application layer always supplies a real
      # value — so fail fast rather than storing or comparing a null.
      # Implementations call this at the top of #increment.
      def validate_arguments!(idempotency_key:, fingerprint:)
        raise ArgumentError, 'idempotency_key must be a non-empty string' \
          unless idempotency_key.is_a?(String) && !idempotency_key.empty?
        raise ArgumentError, 'fingerprint must be a non-empty string' \
          unless fingerprint.is_a?(String) && !fingerprint.empty?
      end
    end
  end
end
