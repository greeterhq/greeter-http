# frozen_string_literal: true

require 'openapi_first'
require 'rack'
require 'yaml'
require 'greeter_http'

# Test support only (ADR 0002): validates every response that the composed app
# produces in RSpec and Cucumber against openapi.yaml, using openapi_first's
# test wrapper. Nothing under lib/, exe/ or infra/ references openapi_first, and
# the gem is in the :test group, so it never enters the Lambda bundle.
#
# Loaded from .rspec (RSpec) and features/support/openapi_contract.rb
# (Cucumber); requiring it installs the wrapper. Only responses are validated:
# tests send invalid requests on purpose.
module OpenapiContract
  DESCRIPTION = File.expand_path('../../openapi.yaml', __dir__)

  # Raised when a response does not match openapi.yaml, or when the description's
  # version is not the service version. A response mismatch starts with
  # "<METHOD> <path> status <status>: " so the failing operation is named.
  class Mismatch < StandardError; end

  # Wraps a Rack app. Validation is silent in openapi_first and raises through
  # its test hooks, so the status is captured here to name it in the message.
  class Checked
    def initialize(app)
      @app = app
    end

    def call(env)
      status = nil
      observed = lambda do |inner_env|
        response = @app.call(inner_env)
        status = response.first
        response
      end
      OpenapiFirst::Test.app(observed).call(env)
    rescue OpenapiFirst::ResponseInvalidError => e
      request = Rack::Request.new(env)
      raise Mismatch, "#{request.request_method} #{request.path_info} status #{status}: #{e.message}"
    end
  end

  # Prepended to GreeterHttp::App's singleton class. build_handler and
  # build_from_env both call build, so every composed app is wrapped. Apps built
  # directly from RackApp or VersionHeaders are deliberately not wrapped.
  module Build
    def build(...)
      Checked.new(super)
    end
  end

  module_function

  # Idempotent: registers openapi.yaml with openapi_first and wraps App.build once.
  def install
    return if @installed

    OpenapiFirst::Test.setup do |test|
      test.register(DESCRIPTION)
      # Tests send invalid requests on purpose, so only responses are validated.
      test.ignore_request_error { true }
      # The gem ignores 401, 404 and 500 by default, which would hide a mismatch
      # in the 500 response this API describes. Unrouted requests (a 404 from a
      # path the API does not define) are skipped by the gem anyway.
      test.ignored_unknown_status = []
      # The gem's coverage gate would end the process with status 2.
      test.report_coverage = false
    end
    GreeterHttp::App.singleton_class.prepend(Build)
    @installed = true
  end

  # True when info.version in the description is GreeterHttp::VERSION.
  # @raise [Mismatch] naming both versions otherwise
  def check_version(path = DESCRIPTION)
    described = YAML.safe_load_file(path, aliases: true).dig('info', 'version').to_s
    return true if described == GreeterHttp::VERSION

    raise Mismatch, "#{File.basename(path)} info.version is #{described.inspect}, " \
                    "but GreeterHttp::VERSION is #{GreeterHttp::VERSION.inspect}"
  end
end

OpenapiContract.install
