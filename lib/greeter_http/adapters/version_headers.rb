# frozen_string_literal: true

require 'greeter/core'
require 'greeter_http/version'

module GreeterHttp
  module Adapters
    # Rack middleware that stamps every response with the deployed versions so
    # black-box clients can see exactly what is running:
    #
    #   x-greeter-version       GreeterHttp::VERSION (no leading "v")
    #   x-greeter-core-version  Greeter::Core::VERSION
    #
    # The values are fixed at construction from the two constants (injectable
    # for specs). The request env is never read, so request input can never
    # influence them, and any value the wrapped app set for these headers is
    # overwritten. Malformed values (leading "v", whitespace, control
    # characters) raise ArgumentError at construction, so a bad value fails at
    # boot and can never reach a response. Exceptions from the wrapped app are
    # deliberately not rescued here.
    class VersionHeaders
      SERVICE_HEADER = 'x-greeter-version'
      CORE_HEADER = 'x-greeter-core-version'
      VERSION_PATTERN = /\A\d+(\.\d+)*([-.][0-9A-Za-z]+)*\z/

      # @param app [#call] the wrapped Rack app
      # @param service_version [String] value for x-greeter-version
      # @param core_version [String] value for x-greeter-core-version
      # @raise [ArgumentError] when a version value is not a plain dotted version
      def initialize(app:, service_version: GreeterHttp::VERSION, core_version: Greeter::Core::VERSION)
        @app = app
        @version_headers = {
          SERVICE_HEADER => validated(service_version, 'service_version'),
          CORE_HEADER => validated(core_version, 'core_version')
        }.freeze
      end

      def call(env)
        status, headers, body = @app.call(env)
        [status, stamp(headers), body]
      end

      private

      def validated(value, name)
        return value.dup.freeze if value.is_a?(String) && value.match?(VERSION_PATTERN)

        raise ArgumentError, "#{name} must be a plain dotted version (e.g. 1.2.3), got #{value.inspect}"
      end

      # Copy the headers, dropping any existing case-variant of ours, then add
      # the fixed values.
      def stamp(headers)
        copy = {}
        (headers || {}).each do |key, value|
          copy[key] = value unless @version_headers.key?(key.to_s.downcase)
        end
        copy.merge(@version_headers)
      end
    end
  end
end
