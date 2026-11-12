# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'aws-sdk-dynamodb'

# Table-driven handler specs over API Gateway v2 (payload format 2.0) event
# fixtures. The handler is a thin adapter: it translates the event into a call
# on the composed Rack app and translates the response back into the API
# Gateway response shape. Business logic lives behind it.
RSpec.describe 'GreeterHttp::Adapters::LambdaHandler' do
  FIXTURES = File.expand_path('../fixtures/events', __dir__)

  def load_event(name)
    JSON.parse(File.read(File.join(FIXTURES, "#{name}.json")))
  end

  # A handler wired to a working in-memory backend for the non-error cases.
  let(:working_handler) do
    GreeterHttp::Adapters::LambdaHandler.new(
      app: GreeterHttp::App.build(
        greeting_counter: GreeterHttp::Adapters::InMemoryGreetingCounter.new
      )
    )
  end

  describe 'response status and body shape' do
    cases = [
      { fixture: 'happy_path',    status: 201 },
      { fixture: 'missing_name',  status: 422 },
      { fixture: 'oversized_name', status: 422 },
      { fixture: 'malformed_json', status: 400 }
    ]

    cases.each do |c|
      context "with the #{c[:fixture]} event" do
        subject(:response) { working_handler.call(event: load_event(c[:fixture])) }

        it "returns HTTP #{c[:status]}" do
          expect(response['statusCode']).to eq(c[:status])
        end

        it 'returns a JSON object body' do
          expect { JSON.parse(response['body']) }.not_to raise_error
          expect(JSON.parse(response['body'])).to be_a(Hash)
        end

        it 'never leaks internal implementation details in the body' do
          expect(response['body']).not_to include('Aws::')
          expect(response['body']).not_to include('Greeter::Core')
          # No Ruby backtrace lines (e.g. "/path/file.rb:123:in `method'").
          expect(response['body']).not_to match(/\.rb:\d+:in /)
        end
      end
    end

    context 'with the happy_path event' do
      subject(:body) { JSON.parse(working_handler.call(event: load_event('happy_path'))['body']) }

      it 'returns the expected success body shape' do
        expect(body).to include(
          'guest_name' => 'Alice Bonsu',
          'greeting' => 'Hello, Alice Bonsu!',
          'count' => 1
        )
        expect(body).to have_key('greeted_at')
      end
    end
  end

  describe 'version headers pass through to API Gateway unchanged' do
    it 'returns both headers for a 201, a 422 and an unrouted 404',
       requirement: 'lambda-handler-preserves-version-headers',
       scenario: 'handler-passes-headers-through' do
      unrouted = {
        'version' => '2.0', 'rawPath' => '/nope', 'rawQueryString' => '', 'headers' => {},
        'requestContext' => { 'http' => { 'method' => 'GET', 'path' => '/nope' } },
        'body' => nil, 'isBase64Encoded' => false
      }
      events = { 'happy_path' => [load_event('happy_path'), 201],
                 'missing_name' => [load_event('missing_name'), 422],
                 'unrouted' => [unrouted, 404] }

      events.each do |label, (event, status)|
        response = working_handler.call(event: event)

        expect(response['statusCode']).to eq(status), "#{label}: unexpected status"
        expect(response['headers']['x-greeter-version']).to eq(GreeterHttp::VERSION), label
        expect(response['headers']['x-greeter-core-version']).to eq(Greeter::Core::VERSION), label
      end
    end
  end

  describe 'when the counter raises a transient DynamoDB error' do
    let(:failing_counter) do
      instance_double(GreeterHttp::Adapters::InMemoryGreetingCounter).tap do |c|
        allow(c).to receive(:increment).and_raise(
          Aws::DynamoDB::Errors::ServiceError.new(nil, 'throughput exceeded')
        )
      end
    end

    let(:handler) do
      GreeterHttp::Adapters::LambdaHandler.new(
        app: GreeterHttp::App.build(greeting_counter: failing_counter)
      )
    end

    subject(:response) { handler.call(event: load_event('happy_path')) }

    it 'returns HTTP 503' do
      expect(response['statusCode']).to eq(503)
    end

    it 'does not leak the Aws error class or a backtrace to the client' do
      expect(response['body']).not_to include('Aws::')
      expect(response['body']).not_to match(/\.rb:\d+:in /)
    end

    it 'returns a JSON object body' do
      expect(JSON.parse(response['body'])).to be_a(Hash)
    end
  end
end
