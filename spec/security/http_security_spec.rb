# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'securerandom'

# HTTP-boundary security properties for the greeter service, exercised end to
# end through the Lambda handler + Rack app over an in-memory counter (no AWS).
#
# These are behavioural guarantees a client/attacker can observe:
#   * raw request input is never reflected verbatim into a response body
#     (no stored/reflected XSS, no echoing of attacker-controlled strings),
#   * no permissive CORS (no access-control-* headers, never a "*" origin),
#   * the request body is capped (a giant body is rejected, not processed),
#   * every malformed/hostile fixture gets a safe, documented 4xx — never a
#     5xx and never a leaked internal.
#
# The fixture statuses are intentional and already contracted in
# spec/adapters/lambda_handler_spec.rb: malformed JSON => 400, but a
# semantically invalid name (empty / too long) => 422. "Malformed" here means
# "not a valid request", and the security property is that each is handled
# safely with the correct 4xx — not that all collapse to 400.
RSpec.describe 'HTTP security properties' do
  FIXTURES = File.expand_path('../fixtures/events', __dir__)

  let(:handler) do
    GreeterHttp::App.build_handler(
      greeting_counter: GreeterHttp::Adapters::InMemoryGreetingCounter.new
    )
  end

  def load_event(name)
    JSON.parse(File.read(File.join(FIXTURES, "#{name}.json")))
  end

  # Build an API Gateway v2 event with the given raw name and (optional) body
  # override, each with a fresh idempotency key.
  def event_for(name: nil, raw_body: nil, headers: {})
    base_headers = { 'content-type' => 'application/json', 'idempotency-key' => SecureRandom.uuid }
    body = raw_body || JSON.generate('name' => name)
    {
      'version' => '2.0',
      'routeKey' => 'POST /greetings',
      'rawPath' => '/greetings',
      'rawQueryString' => '',
      'headers' => base_headers.merge(headers),
      'requestContext' => { 'http' => { 'method' => 'POST', 'path' => '/greetings' } },
      'body' => body,
      'isBase64Encoded' => false
    }
  end

  # A greeting service must echo the guest's name back ("Hello, <name>!"), so
  # the security property is NOT "never reflect input" (impossible). It is the
  # combination of:
  #   (B) reject names carrying HTML/template/escape metacharacters at the HTTP
  #       boundary — the classic reflected-XSS / SSTI probes — with a static
  #       422, so they are never echoed; and
  #   (A) for everything that IS accepted, the body is always well-formed JSON
  #       with the value safely escaped, so input can never break out of the
  #       JSON string context (no injection, no response splitting).
  describe 'hostile metacharacter names are rejected (B)' do
    # Each contains at least one forbidden metacharacter (< > { } \).
    probes = {
      'script tag' => '<script>alert(1)</script>',
      'img breakout' => '"><img src=x onerror=alert(1)>',
      'template expr' => '{{7*7}}',
      'backslash escape' => 'alice\\u0000'
    }

    probes.each do |label, payload|
      it "422s the #{label} probe and never echoes it" do
        response = handler.call(event: event_for(name: payload))

        expect(response['statusCode']).to eq(422)
        # The attacker-controlled payload (and its dangerous substrings) never
        # appears in the body. (The body is a JSON object, so it legitimately
        # contains structural braces; we assert the INPUT is absent, not that
        # the body has no braces.)
        expect(response['body']).not_to include(payload)
        expect(response['body']).not_to include('<script>')
        expect(response['body']).not_to include('onerror=')
        expect(response['body']).not_to include('{{')
      end
    end

    it 'returns only a fixed code + static message (no reflection) on rejection' do
      response = handler.call(event: event_for(name: '<script>'))
      parsed = JSON.parse(response['body'])

      expect(parsed.keys).to contain_exactly('error', 'message')
      expect(parsed['error']).to eq('invalid_name')
      expect(parsed['message']).not_to include('<script>')
      expect(parsed['message']).to match(/\AName/)
    end
  end

  describe 'accepted input is always safely JSON-encoded (A)' do
    # A name with punctuation that is ALLOWED (no < > { } \) — apostrophes,
    # hyphens, semicolons, quotes. It is echoed back, but must stay safely
    # inside the JSON string, never breaking the body's structure.
    it 'echoes an allowed punctuated name as valid, escaped JSON' do
      response = handler.call(event: event_for(name: %q(o'brien "lee"; drop)))

      expect(response['statusCode']).to eq(201)
      # The body parses as JSON (nothing in the input broke the structure)...
      body = JSON.parse(response['body'])
      expect(body).to be_a(Hash)
      # ...and the apostrophe survives (core titlecases via String#capitalize,
      # which lowercases the tail of each whitespace-split word).
      expect(body['guest_name']).to include("O'brien")
    end

    it 'preserves apostrophes and hyphens in ordinary names' do
      response = handler.call(event: event_for(name: "jean-luc o'brien"))
      body = JSON.parse(response['body'])

      expect(response['statusCode']).to eq(201)
      # Core's titlecase is value.split.map(&:capitalize).join(' '); capitalize
      # uppercases only the first char and downcases the rest, and split is on
      # whitespace (not '-'), so "jean-luc" => "Jean-luc".
      expect(body['guest_name']).to eq("Jean-luc O'brien")
    end

    it 'the content-type is application/json so bodies are not interpreted as HTML' do
      response = handler.call(event: event_for(name: 'alice bonsu'))
      ctype = response['headers'].find { |k, _| k.to_s.downcase == 'content-type' }&.last
      expect(ctype).to eq('application/json')
    end
  end

  describe 'no permissive CORS' do
    it 'sets no access-control-* headers on a success response' do
      response = handler.call(event: event_for(name: 'alice bonsu'))
      cors = response['headers'].keys.select { |k| k.to_s.downcase.start_with?('access-control-') }
      expect(cors).to be_empty
    end

    it 'sets no access-control-* headers on an error response' do
      response = handler.call(event: event_for(name: ''))
      cors = response['headers'].keys.select { |k| k.to_s.downcase.start_with?('access-control-') }
      expect(cors).to be_empty
    end

    it 'never emits a wildcard allow-origin anywhere in the response' do
      response = handler.call(event: event_for(name: 'alice bonsu'))
      header_values = response['headers'].map { |_k, v| v.to_s }
      expect(header_values).not_to include('*')
      expect(response['headers'].keys.map { |k| k.to_s.downcase }).not_to include('access-control-allow-origin')
    end
  end

  describe 'version disclosure is limited to the two version headers' do
    it 'sends no other server/version/powered-by header on a 201, 422 or 404',
       requirement: 'version-headers-disclose-nothing-beyond-the-two-versions',
       scenario: 'no-other-version-disclosing-headers' do
      unrouted = {
        'version' => '2.0', 'rawPath' => '/nope', 'rawQueryString' => '', 'headers' => {},
        'requestContext' => { 'http' => { 'method' => 'GET', 'path' => '/nope' } },
        'body' => nil, 'isBase64Encoded' => false
      }
      responses = [handler.call(event: event_for(name: 'alice bonsu')),
                   handler.call(event: event_for(name: '')),
                   handler.call(event: unrouted)]

      expect(responses.map { |r| r['statusCode'] }).to eq([201, 422, 404])
      responses.each do |response|
        disclosing = response['headers'].keys.map { |k| k.to_s.downcase }
                                        .grep(/version|server|powered/)
        expect(disclosing).to contain_exactly('x-greeter-version', 'x-greeter-core-version')
      end
    end
  end

  describe 'request body is capped' do
    it 'rejects an oversized body with 413 instead of processing it' do
      # Far larger than MAX_BODY_BYTES; a valid-looking JSON object so the only
      # reason to reject is size, not malformed JSON.
      huge = JSON.generate('name' => 'a' * (64 * 1024))
      response = handler.call(event: event_for(raw_body: huge))

      expect(response['statusCode']).to eq(413)
      expect(JSON.parse(response['body'])['error']).to eq('payload_too_large')
    end

    it 'rejects an oversized body even when Content-Length is understated' do
      huge = JSON.generate('name' => 'a' * (64 * 1024))
      # Lie about the length; the capped read must still stop it.
      response = handler.call(event: event_for(raw_body: huge, headers: { 'content-length' => '10' }))

      expect(response['statusCode']).to eq(413)
    end

    it 'accepts a normal small body' do
      response = handler.call(event: event_for(name: 'alice bonsu'))
      expect(response['statusCode']).to eq(201)
    end
  end

  describe 'every malformed fixture returns a safe 4xx' do
    # The security property is that each malformed/hostile request is rejected
    # with a client error (4xx) carrying a safe body — never a 5xx, never a
    # leaked internal. The specific code is intentional and documented
    # (malformed JSON => 400; semantically invalid name => 422), but the gate
    # here is the 4xx class, per the requirement.
    fixtures = %w[malformed_json missing_name oversized_name]

    fixtures.each do |fixture|
      context "with the #{fixture} fixture" do
        subject(:response) { handler.call(event: load_event(fixture)) }

        it 'returns a 4xx client error' do
          expect(response['statusCode']).to be_between(400, 499).inclusive
        end

        it 'returns a safe JSON error object (code + message only)' do
          parsed = JSON.parse(response['body'])
          expect(parsed).to be_a(Hash)
          expect(parsed.keys).to contain_exactly('error', 'message')
        end

        it 'never returns 5xx and never leaks internals' do
          expect(response['statusCode']).to be < 500
          expect(response['body']).not_to include('Aws::')
          expect(response['body']).not_to include('Greeter::Core')
          expect(response['body']).not_to match(/\.rb:\d+:in /)
        end
      end
    end
  end
end
