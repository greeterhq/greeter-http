# frozen_string_literal: true

require 'spec_helper'
require 'aws-sdk-dynamodb'
require 'json'
require 'rack'
require 'rack/mock'
require 'securerandom'
require 'yaml'

# OpenapiContract (spec/support/openapi_contract.rb) wraps the composed app so
# every response it produces in a test is validated against openapi.yaml. It is
# loaded through .rspec once the implementation group has added it, so before
# then each example fails with a NameError.
#
# Interface under test:
#   OpenapiContract::Checked.new(rack_app)   a Rack app that validates responses
#   OpenapiContract::Mismatch                raised on a mismatch; the message starts
#                                            "POST /greetings status <status>: "
#   OpenapiContract::Build                   prepended to GreeterHttp::App.singleton_class
#   OpenapiContract.install                  idempotent
RSpec.describe 'OpenapiContract' do
  let(:repo_root) { File.expand_path('../..', __dir__) }
  let(:fixtures) do
    YAML.safe_load_file(File.join(repo_root, 'spec', 'fixtures', 'openapi', 'responses.yml'), aliases: true)
  end

  # A Rack app that always answers with one fixed response from responses.yml.
  def fixed_app(entry)
    status = entry.fetch('status')
    headers = entry.fetch('headers')
    body = JSON.generate(entry.fetch('body'))
    ->(_env) { [status, headers.dup, [body]] }
  end

  def checked(group, name)
    OpenapiContract::Checked.new(fixed_app(fixtures.fetch(group).fetch(name)))
  end

  def post_env
    Rack::MockRequest.env_for('/greetings', method: 'POST', input: '{"name":"Ada Example"}',
                                            'CONTENT_TYPE' => 'application/json', 'HTTP_IDEMPOTENCY_KEY' => 'key-1')
  end

  def read(response)
    status, headers, body = response
    [status, headers, body.each.to_a.join]
  end

  describe 'described responses',
           requirement: 'every-response-of-the-composed-app-matches-openapi-yaml',
           scenario: 'described-responses-pass' do
    %w[created_201 replay_200 counter_disabled_201 missing_key_400 conflict_409 too_large_413
       invalid_name_422 internal_500 unavailable_503].each do |name|
      it "passes #{name} through unchanged", :aggregate_failures do
        entry = fixtures.fetch('described').fetch(name)

        status, headers, body = read(checked('described', name).call(post_env))

        expect(status).to eq(entry['status'])
        expect(headers).to eq(entry['headers'])
        expect(body).to eq(JSON.generate(entry['body']))
      end
    end

    describe 'from the composed app' do
      let(:counter) { GreeterHttp::Adapters::InMemoryGreetingCounter.new }
      let(:app) { GreeterHttp::App.build(greeting_counter: counter) }
      let(:request) { Rack::MockRequest.new(app) }

      before { expect(app).to be_a(OpenapiContract::Checked) }

      def greet(name: 'ada example', key: SecureRandom.uuid, body: nil)
        headers = { 'CONTENT_TYPE' => 'application/json', input: body || JSON.generate('name' => name) }
        headers['HTTP_IDEMPOTENCY_KEY'] = key if key
        request.post('/greetings', headers)
      end

      it 'returns 201 for a first greeting and 200 for its replay, both validated', :aggregate_failures do
        key = SecureRandom.uuid

        expect(greet(key: key).status).to eq(201)
        expect(greet(key: key).status).to eq(200)
      end

      it 'returns 400, 409, 413 and 422 for bad requests, all validated', :aggregate_failures do
        key = SecureRandom.uuid
        greet(key: key)

        expect(greet(key: nil).status).to eq(400)
        expect(greet(name: 'grace hopper', key: key).status).to eq(409)
        expect(greet(name: 'a' * 70_000).status).to eq(413)
        expect(greet(name: '').status).to eq(422)
      end

      context 'when storage is unavailable' do
        let(:counter) do
          instance_double(GreeterHttp::Adapters::InMemoryGreetingCounter).tap do |double|
            allow(double).to receive(:increment).and_raise(Aws::DynamoDB::Errors::ServiceError.new(nil, 'throttled'))
          end
        end

        it 'returns 503 with Retry-After, validated' do
          expect(greet.status).to eq(503)
        end
      end

      context 'when the counter raises an unexpected error' do
        let(:counter) do
          instance_double(GreeterHttp::Adapters::InMemoryGreetingCounter).tap do |double|
            allow(double).to receive(:increment).and_raise(RuntimeError, 'boom')
          end
        end

        it 'returns 500, validated' do
          expect(greet.status).to eq(500)
        end
      end
    end
  end

  describe 'an undocumented status',
           requirement: 'every-response-of-the-composed-app-matches-openapi-yaml',
           scenario: 'an-undocumented-status-fails-and-is-named' do
    it 'fails naming POST /greetings and the status 418' do
      expect { checked('undescribed', 'teapot_418').call(post_env) }
        .to raise_error(OpenapiContract::Mismatch, a_string_starting_with('POST /greetings status 418:'))
    end

    it 'fails a 500 whose body does not match, so 500 is not silently ignored' do
      expect { checked('undescribed', 'leaky_500').call(post_env) }
        .to raise_error(OpenapiContract::Mismatch, a_string_starting_with('POST /greetings status 500:'))
    end
  end

  describe 'a field mismatch',
           requirement: 'every-response-of-the-composed-app-matches-openapi-yaml',
           scenario: 'a-field-mismatch-fails-and-is-named' do
    %w[extra_field_201 missing_count_201 string_count_201].each do |name|
      it "fails #{name} naming POST /greetings and the status 201" do
        expect { checked('undescribed', name).call(post_env) }
          .to raise_error(OpenapiContract::Mismatch, a_string_starting_with('POST /greetings status 201:'))
      end
    end
  end

  describe 'a missing version header',
           requirement: 'every-response-of-the-composed-app-matches-openapi-yaml',
           scenario: 'a-missing-version-header-fails-and-is-named' do
    it 'fails naming POST /greetings and the status 200' do
      expect { checked('undescribed', 'missing_core_header_200').call(post_env) }
        .to raise_error(OpenapiContract::Mismatch, a_string_starting_with('POST /greetings status 200:'))
    end
  end

  describe 'unrouted requests',
           requirement: 'every-response-of-the-composed-app-matches-openapi-yaml',
           scenario: 'unrouted-requests-are-not-validated' do
    {
      'GET /nope' => '/nope',
      'GET /greetings' => '/greetings'
    }.each do |label, path|
      it "passes the 404 for #{label} through unchanged", :aggregate_failures do
        entry = fixtures.fetch('unrouted').fetch('not_found_404')
        wrapper = OpenapiContract::Checked.new(fixed_app(entry))

        status, headers, body = read(wrapper.call(Rack::MockRequest.env_for(path)))

        expect(status).to eq(404)
        expect(headers).to eq(entry['headers'])
        expect(body).to eq(JSON.generate(entry['body']))
      end
    end
  end

  describe 'installation on GreeterHttp::App',
           requirement: 'every-response-of-the-composed-app-matches-openapi-yaml',
           scenario: 'described-responses-pass' do
    it 'is prepended once to GreeterHttp::App, however often install runs', :aggregate_failures do
      2.times { OpenapiContract.install }

      expect(GreeterHttp::App.singleton_class.ancestors.count(OpenapiContract::Build)).to eq(1)
    end

    it 'wraps what App.build returns' do
      built = GreeterHttp::App.build(greeting_counter: GreeterHttp::Adapters::InMemoryGreetingCounter.new)

      expect(built).to be_a(OpenapiContract::Checked)
    end

    it 'wraps the app inside build_handler too' do
      handler = GreeterHttp::App.build_handler(greeting_counter: GreeterHttp::Adapters::InMemoryGreetingCounter.new)

      # The handler keeps the composed Rack app in @app; reading it is the only
      # way to see whether build_handler went through the wrapped build.
      expect(handler.instance_variable_get(:@app)).to be_a(OpenapiContract::Checked)
    end
  end

  describe 'Cucumber support',
           requirement: 'every-response-of-the-composed-app-matches-openapi-yaml',
           scenario: 'cucumber-validates-through-the-same-support' do
    it 'is loaded by Cucumber from features/support, from the same shared support file', :aggregate_failures do
      support = File.join(repo_root, 'features', 'support', 'openapi_contract.rb')

      expect(File).to exist(support)
      expect(File.read(support)).to match(%r{require.*spec/support/openapi_contract})
    end
  end
end
