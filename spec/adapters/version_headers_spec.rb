# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'securerandom'
require 'rack'
require 'aws-sdk-dynamodb'

# Red tests for the add-version-header change (capability: version-headers).
#
# Every example carries `requirement:` and `scenario:` metadata whose values are
# the slugs of the OpenSpec requirement and scenario headings (lowercase,
# non-alphanumerics -> "-", repeats squeezed, ends stripped). Each OpenSpec
# scenario maps to exactly one example.
#
# Most examples drive the composed Rack app (App.build) so they prove the
# middleware is wired in the composition root. Examples that construct
# GreeterHttp::Adapters::VersionHeaders directly fail red with NameError until
# the middleware exists.
RSpec.describe 'version headers' do
  SERVICE_HEADER = 'x-greeter-version'
  CORE_HEADER = 'x-greeter-core-version'

  let(:counter) { GreeterHttp::Adapters::InMemoryGreetingCounter.new }
  let(:app) { GreeterHttp::App.build(greeting_counter: counter) }
  let(:request) { Rack::MockRequest.new(app) }

  def post_greeting(name: 'alice bonsu', key: SecureRandom.uuid, body: nil, headers: {}, req: request)
    env = { 'CONTENT_TYPE' => 'application/json',
            input: body || JSON.generate('name' => name) }
    env['HTTP_IDEMPOTENCY_KEY'] = key if key
    req.post('/greetings', env.merge(headers))
  end

  def expect_version_headers(response)
    expect(response.get_header(SERVICE_HEADER)).to eq(GreeterHttp::VERSION)
    expect(response.get_header(CORE_HEADER)).to eq(Greeter::Core::VERSION)
  end

  # Not an OpenSpec scenario: pins the release bump so the headers advertise 0.5.20.
  it 'is released as service version 0.5.20' do
    expect(GreeterHttp::VERSION).to eq('0.5.20')
  end

  describe 'successful greetings' do
    it 'carries both headers on a 201',
       requirement: 'successful-greetings-carry-version-headers',
       scenario: 'created-greeting-carries-both-headers' do
      response = post_greeting

      expect(response.status).to eq(201)
      expect_version_headers(response)
    end

    it 'carries both headers on a 200 replay with the same values as the 201',
       requirement: 'successful-greetings-carry-version-headers',
       scenario: 'replayed-greeting-carries-both-headers' do
      key = SecureRandom.uuid
      created = post_greeting(key: key)
      replayed = post_greeting(key: key)

      expect(created.status).to eq(201)
      expect(replayed.status).to eq(200)
      expect_version_headers(replayed)
      expect(replayed.get_header(SERVICE_HEADER)).to eq(created.get_header(SERVICE_HEADER))
      expect(replayed.get_header(CORE_HEADER)).to eq(created.get_header(CORE_HEADER))
    end
  end

  describe 'rejected requests' do
    it 'carry both headers on a 400 for malformed JSON and for a missing key',
       requirement: 'rejected-requests-carry-version-headers',
       scenario: 'malformed-or-missing-key-request-carries-both-headers' do
      malformed = post_greeting(body: '{not json')
      missing_key = post_greeting(key: nil)

      expect([malformed.status, missing_key.status]).to eq([400, 400])
      expect_version_headers(malformed)
      expect_version_headers(missing_key)
    end

    it 'carry both headers on a 409 when a key is reused with a different name',
       requirement: 'rejected-requests-carry-version-headers',
       scenario: 'key-reuse-carries-both-headers' do
      key = SecureRandom.uuid
      post_greeting(name: 'alice bonsu', key: key)
      response = post_greeting(name: 'carol kay', key: key)

      expect(response.status).to eq(409)
      expect_version_headers(response)
    end

    it 'carry both headers on a 413 for an oversized body',
       requirement: 'rejected-requests-carry-version-headers',
       scenario: 'oversized-body-carries-both-headers' do
      response = post_greeting(name: 'a' * (64 * 1024))

      expect(response.status).to eq(413)
      expect_version_headers(response)
    end

    it 'carry both headers on a 422 for an invalid name',
       requirement: 'rejected-requests-carry-version-headers',
       scenario: 'invalid-name-carries-both-headers' do
      response = post_greeting(name: '')

      expect(response.status).to eq(422)
      expect(JSON.parse(response.body)['error']).to eq('invalid_name')
      expect_version_headers(response)
    end
  end

  describe 'storage failures' do
    let(:counter) do
      instance_double(GreeterHttp::Adapters::InMemoryGreetingCounter).tap do |c|
        allow(c).to receive(:increment).and_raise(
          Aws::DynamoDB::Errors::ServiceError.new(nil, 'throughput exceeded')
        )
      end
    end

    it 'carry both headers on a 503 and keep Retry-After',
       requirement: 'storage-failures-carry-version-headers',
       scenario: 'storage-unavailable-carries-both-headers' do
      response = post_greeting

      expect(response.status).to eq(503)
      expect(response.get_header('retry-after')).not_to be_nil
      expect_version_headers(response)
    end
  end

  describe 'unrouted requests' do
    it 'carry both headers on a 404 for an unrouted path',
       requirement: 'unrouted-requests-carry-version-headers',
       scenario: 'unrouted-path-carries-both-headers' do
      response = request.get('/nope')

      expect(response.status).to eq(404)
      expect_version_headers(response)
    end

    it 'carry both headers on a 404 for GET /greetings',
       requirement: 'unrouted-requests-carry-version-headers',
       scenario: 'unsupported-method-on-the-greetings-path-carries-both-headers' do
      response = request.get('/greetings')

      expect(response.status).to eq(404)
      expect_version_headers(response)
    end
  end

  describe 'unexpected errors' do
    let(:counter) do
      instance_double(GreeterHttp::Adapters::InMemoryGreetingCounter).tap do |c|
        allow(c).to receive(:increment).and_raise(RuntimeError, 'boom')
      end
    end

    it 'carry both headers on a 500',
       requirement: 'unexpected-errors-carry-version-headers',
       scenario: 'unexpected-exception-carries-both-headers' do
      response = post_greeting

      expect(response.status).to eq(500)
      expect(JSON.parse(response.body)['error']).to eq('internal_error')
      expect_version_headers(response)
    end
  end

  describe 'header values are fixed by the build' do
    it 'ignores version headers supplied by the client',
       requirement: 'version-header-values-are-fixed-by-the-build',
       scenario: 'request-input-cannot-change-the-values' do
      response = post_greeting(headers: { 'HTTP_X_GREETER_VERSION' => '9.9.9-evil',
                                          'HTTP_X_GREETER_CORE_VERSION' => '8.8.8-evil' })

      expect(response.status).to eq(201)
      expect_version_headers(response)
    end

    it 'ignores version-looking environment variables',
       requirement: 'version-header-values-are-fixed-by-the-build',
       scenario: 'environment-cannot-change-the-values' do
      overrides = { 'GREETER_VERSION' => '9.9.9', 'GREETER_CORE_VERSION' => '8.8.8',
                    'VERSION' => '7.7.7' }
      saved = overrides.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
      overrides.each { |k, v| ENV[k] = v }
      begin
        response = post_greeting
        expect_version_headers(response)
      ensure
        saved.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
      end
    end

    it 'overwrites a different value set by the inner app',
       requirement: 'version-header-values-are-fixed-by-the-build',
       scenario: 'inner-application-value-is-overwritten' do
      inner = ->(_env) { [200, { SERVICE_HEADER => 'evil', CORE_HEADER => 'evil' }, ['ok']] }
      wrapped = GreeterHttp::Adapters::VersionHeaders.new(app: inner)

      response = Rack::MockRequest.new(wrapped).get('/')

      expect_version_headers(response)
    end
  end

  describe 'disclosure limits' do
    it 'refuses to be constructed with a malformed version value',
       requirement: 'version-headers-disclose-nothing-beyond-the-two-versions',
       scenario: 'malformed-version-value-is-rejected-at-startup' do
      inner = ->(_env) { [200, {}, ['ok']] }
      bad_values = ['v0.5.20', "0.5.20\r\nX-Evil: 1", ' 0.5.20', '', nil]

      bad_values.each do |bad|
        expect { GreeterHttp::Adapters::VersionHeaders.new(app: inner, service_version: bad) }
          .to raise_error(ArgumentError), "expected ArgumentError for service_version=#{bad.inspect}"
        expect { GreeterHttp::Adapters::VersionHeaders.new(app: inner, core_version: bad) }
          .to raise_error(ArgumentError), "expected ArgumentError for core_version=#{bad.inspect}"
      end
    end
  end

  describe 'synthetic marker' do
    it 'does not change status, body or headers and is not echoed',
       requirement: 'synthetic-marker-does-not-alter-version-headers-or-responses',
       scenario: 'synthetic-request-matches-non-synthetic-response' do
      clock = Greeter::Core::Testing::FixedClock.new
      key = SecureRandom.uuid
      build = lambda do
        Rack::MockRequest.new(
          GreeterHttp::App.build(
            greeting_counter: GreeterHttp::Adapters::InMemoryGreetingCounter.new, clock: clock
          )
        )
      end

      plain = post_greeting(key: key, req: build.call)
      synthetic = post_greeting(key: key, req: build.call,
                                headers: { 'HTTP_X_GREETER_SYNTHETIC' => 'true' })

      expect(synthetic.status).to eq(plain.status)
      expect(synthetic.body).to eq(plain.body)
      expect(synthetic.headers.to_h).to eq(plain.headers.to_h)
      expect_version_headers(synthetic)
      expect(synthetic.headers.keys.map(&:downcase)).not_to include('x-greeter-synthetic')
    end
  end
end
