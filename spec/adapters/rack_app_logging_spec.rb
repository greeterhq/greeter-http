# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'digest'
require 'stringio'
require 'rack'

# Structured per-request logging (item 3) and the synthetic-traffic marker
# (item 4) at the HTTP boundary. Drives the Rack app directly with a crafted
# env, a capturing logger, and a stubbed monotonic clock so duration is
# deterministic.
RSpec.describe 'GreeterHttp::Adapters::RackApp structured logging' do
  # Capturing logger: records each structured entry instead of writing stderr.
  # A minimal duck-typed logger (the port only needs #info); not a verified
  # double because RackApp logs to any object responding to #info, not Logger.
  let(:captured) { [] }
  let(:logger) do
    cap = captured
    Object.new.tap do |o|
      o.define_singleton_method(:info) { |entry| cap << entry }
    end
  end

  # Monotonic stub: returns 1.0 then 1.025 so duration is exactly 25.0 ms.
  let(:monotonic) do
    times = [1.0, 1.025]
    -> { times.shift || 1.025 }
  end

  # The use case, composed the same way App.build does. App.build returns the
  # RackApp wrapped in middleware, so this spec builds the RackApp itself
  # rather than reaching into App.build's result.
  let(:use_case) do
    GreeterHttp::Application::GreetAndCount.new(
      greeting_service: Greeter::Core::Domain::GreetingService.new(
        clock: GreeterHttp::Adapters::SystemClock.new
      ),
      greeting_counter: GreeterHttp::Adapters::InMemoryGreetingCounter.new
    )
  end

  # The RackApp under test, with our logger/monotonic injected.
  let(:rack_app) do
    GreeterHttp::Adapters::RackApp.new(
      use_case: use_case,
      presenter: GreeterHttp::Adapters::JsonPresenter.new,
      logger: logger,
      monotonic: monotonic
    )
  end

  def env_for(name:, key: SecureRandom.uuid, headers: {})
    base = {
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => '/greetings',
      'HTTP_IDEMPOTENCY_KEY' => key,
      'rack.input' => StringIO.new(JSON.generate('name' => name))
    }
    base['CONTENT_TYPE'] = 'application/json'
    headers.each { |h, v| base[h] = v }
    base
  end

  def last_log
    captured.last
  end

  describe 'a successful greeting' do
    before { rack_app.call(env_for(name: 'alice bonsu')) }

    it 'logs exactly one entry' do
      expect(captured.size).to eq(1)
    end

    it 'records the outcome, status and deterministic duration' do
      expect(last_log).to include('outcome' => 'created', 'status' => 201, 'duration_ms' => 25.0)
    end

    it 'includes the composed greeter-core version' do
      expect(last_log['greeter_core_version']).to eq(Greeter::Core::VERSION)
    end

    it 'logs a SHA-256 hash of the name, never the name itself' do
      expect(last_log['name_hash']).to eq("sha256:#{Digest::SHA256.hexdigest('alice bonsu')}")
      expect(last_log['name_hash']).not_to include('alice')
    end

    it 'marks non-synthetic traffic as synthetic=false' do
      expect(last_log['synthetic']).to be(false)
    end
  end

  describe 'correlation id' do
    it 'is taken from the x-amzn-trace-id header' do
      rack_app.call(env_for(name: 'alice bonsu', headers: { 'HTTP_X_AMZN_TRACE_ID' => 'Root=1-abc' }))
      expect(last_log['correlation_id']).to eq('Root=1-abc')
    end

    it 'is null when no trace header is present' do
      rack_app.call(env_for(name: 'alice bonsu'))
      expect(last_log['correlation_id']).to be_nil
    end
  end

  describe 'the synthetic marker' do
    it 'tags the log line when x-greeter-synthetic: true' do
      rack_app.call(env_for(name: 'alice bonsu', headers: { 'HTTP_X_GREETER_SYNTHETIC' => 'true' }))
      expect(last_log['synthetic']).to be(true)
    end

    it 'does not tag when the header is absent or not "true"' do
      rack_app.call(env_for(name: 'alice bonsu', headers: { 'HTTP_X_GREETER_SYNTHETIC' => 'no' }))
      expect(last_log['synthetic']).to be(false)
    end
  end

  describe 'a rejected request' do
    it 'logs the invalid_name outcome with a 422 and no name leak' do
      rack_app.call(env_for(name: '<script>'))
      expect(last_log).to include('outcome' => 'invalid_name', 'status' => 422)
      expect(JSON.generate(last_log)).not_to include('<script>')
    end

    it 'logs malformed_request for a bad JSON body' do
      env = env_for(name: 'x').merge('rack.input' => StringIO.new('{not json'))
      rack_app.call(env)
      expect(last_log).to include('outcome' => 'malformed_request', 'status' => 400)
    end
  end
end
