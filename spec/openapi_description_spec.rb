# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

# openapi.yaml is the hand-written description of POST /greetings (ADR 0002).
# These examples read it as plain YAML, so they check what the file says, not
# what a library makes of it. OpenapiContract (spec/support/openapi_contract.rb)
# is loaded through .rspec once the implementation group has added it.
RSpec.describe 'openapi.yaml' do
  let(:repo_root) { File.expand_path('..', __dir__) }
  let(:description_path) { File.join(repo_root, 'openapi.yaml') }
  let(:description) { YAML.safe_load_file(description_path, aliases: true) }
  let(:operation) { description.dig('paths', '/greetings', 'post') }
  let(:responses) { operation.fetch('responses').transform_keys(&:to_s) }
  let(:version_headers) { %w[X-Greeter-Version X-Greeter-Core-Version] }

  # Follows a local `$ref` such as '#/components/schemas/Greeting'.
  def deref(node)
    while node.is_a?(Hash) && node['$ref']
      node = node['$ref'].delete_prefix('#/').split('/').reduce(description) do |current, key|
        current.fetch(key.gsub('~1', '/').gsub('~0', '~'))
      end
    end
    node
  end

  def response(status)
    deref(responses.fetch(status))
  end

  def body_schema(status)
    deref(response(status).dig('content', 'application/json', 'schema'))
  end

  def properties(schema)
    schema.fetch('properties').transform_values { |property| deref(property) }
  end

  def header(response, name)
    headers = (response['headers'] || {}).transform_keys(&:downcase)
    deref(headers[name.downcase])
  end

  describe 'the request',
           requirement: 'the-api-is-described-by-openapi-yaml',
           scenario: 'the-request-is-described' do
    let(:parameters) { operation.fetch('parameters').map { |parameter| deref(parameter) } }

    def parameter(name)
      parameters.find { |candidate| candidate['name'] == name && candidate['in'] == 'header' }
    end

    it 'describes POST /greetings as OpenAPI 3.1' do
      expect(description['openapi']).to start_with('3.1')
      expect(operation).not_to be_nil
    end

    it 'has a required JSON request body with a required string name', :aggregate_failures do
      body = deref(operation['requestBody'])
      schema = deref(body.dig('content', 'application/json', 'schema'))

      expect(body['required']).to be(true)
      expect(schema['type']).to eq('object')
      expect(schema['required']).to include('name')
      expect(properties(schema).fetch('name')['type']).to eq('string')
    end

    it 'has a required Idempotency-Key header: a string, minLength 1, no format, asking for a UUID',
       :aggregate_failures do
      key = parameter('Idempotency-Key')
      schema = deref(key['schema'])

      expect(key['required']).to be(true)
      expect(schema['type']).to eq('string')
      expect(schema['minLength']).to eq(1)
      expect(schema).not_to include('format')
      expect(key['description']).to match(/UUID/i)
    end

    it 'has an optional X-Greeter-Synthetic header', :aggregate_failures do
      synthetic = parameter('X-Greeter-Synthetic')

      expect(synthetic).not_to be_nil
      expect(synthetic['required']).not_to be(true)
    end
  end

  describe 'success responses',
           requirement: 'the-api-is-described-by-openapi-yaml',
           scenario: 'success-responses-are-described' do
    %w[201 200].each do |status|
      it "describes #{status} with exactly guest_name, greeting, count and greeted_at", :aggregate_failures do
        schema = body_schema(status)
        fields = properties(schema)

        expect(schema['required']).to contain_exactly('guest_name', 'greeting', 'count', 'greeted_at')
        expect(fields.keys).to contain_exactly('guest_name', 'greeting', 'count', 'greeted_at')
        expect(schema['additionalProperties']).to be(false)
        expect(fields['guest_name']['type']).to eq('string')
        expect(fields['greeting']['type']).to eq('string')
        expect(Array(fields['count']['type'])).to contain_exactly('integer', 'null')
        expect(fields['greeted_at']['format']).to eq('date-time')
      end
    end

    it 'says 201 is a new greeting and 200 is a replay', :aggregate_failures do
      expect(response('201')['description']).to match(/new greeting/i)
      expect(response('200')['description']).to match(/replay/i)
    end
  end

  describe 'error responses',
           requirement: 'the-api-is-described-by-openapi-yaml',
           scenario: 'error-responses-are-described' do
    {
      '400' => %w[missing_idempotency_key malformed_request],
      '409' => %w[idempotency_key_reused],
      '413' => %w[payload_too_large],
      '422' => %w[invalid_name],
      '500' => %w[internal_error],
      '503' => %w[temporarily_unavailable]
    }.each do |status, codes|
      it "describes #{status} with exactly error and message, error being #{codes.join(' or ')}",
         :aggregate_failures do
        schema = body_schema(status)
        fields = properties(schema)

        expect(schema['required']).to contain_exactly('error', 'message')
        expect(fields.keys).to contain_exactly('error', 'message')
        expect(schema['additionalProperties']).to be(false)
        expect(fields['error']['enum']).to match_array(codes)
      end
    end

    it 'gives 503 a Retry-After header' do
      expect(header(response('503'), 'Retry-After')).not_to be_nil
    end
  end

  describe 'statuses',
           requirement: 'the-api-is-described-by-openapi-yaml',
           scenario: 'only-the-returned-statuses-are-described' do
    it 'defines exactly 200, 201, 400, 409, 413, 422, 500 and 503, with no 404, 415 or default',
       :aggregate_failures do
      expect(responses.keys).to contain_exactly('200', '201', '400', '409', '413', '422', '500', '503')
      expect(responses.keys & %w[404 415 default]).to be_empty
    end

    it 'describes no other path, no other method and no servers', :aggregate_failures do
      methods = %w[get put post delete options head patch trace]

      expect(description['paths'].keys).to eq(['/greetings'])
      expect(description['paths']['/greetings'].keys & methods).to eq(['post'])
      expect(description).not_to include('servers')
    end
  end

  describe 'version headers',
           requirement: 'the-api-is-described-by-openapi-yaml',
           scenario: 'every-response-carries-both-version-headers' do
    %w[200 201 400 409 413 422 500 503].each do |status|
      it "lists both version headers as required strings on #{status}", :aggregate_failures do
        version_headers.each do |name|
          found = header(response(status), name)

          expect(found).not_to be_nil, "#{status} has no #{name}"
          expect(found['required']).to be(true)
          expect(deref(found['schema'])['type']).to eq('string')
        end
      end
    end
  end

  describe 'the version',
           requirement: 'the-description-version-tracks-the-service-version',
           scenario: 'matching-versions-pass' do
    it 'equals GreeterHttp::VERSION', :aggregate_failures do
      expect(description.dig('info', 'version')).to eq(GreeterHttp::VERSION)
      expect(OpenapiContract.check_version(description_path)).to be(true)
    end
  end

  describe 'a different version',
           requirement: 'the-description-version-tracks-the-service-version',
           scenario: 'differing-versions-fail' do
    it 'fails and names both versions' do
      fixture = File.join(repo_root, 'spec', 'fixtures', 'openapi', 'version_mismatch.yaml')

      expect { OpenapiContract.check_version(fixture) }
        .to raise_error(OpenapiContract::Mismatch, a_string_including('0.0.1', GreeterHttp::VERSION))
    end
  end
end
