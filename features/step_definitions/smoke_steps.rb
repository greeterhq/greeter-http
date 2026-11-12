# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'securerandom'

# Smoke steps run against a real deployed endpoint. When GREETER_BASE_URL is
# not set, every @smoke scenario is skipped so local/CI runs make no network
# calls.
Before('@smoke') do
  skip_this_scenario('GREETER_BASE_URL not set; skipping deployed smoke test') \
    if ENV['GREETER_BASE_URL'].to_s.empty?
end

def smoke_post(base_url, name, idempotency_key)
  uri = URI.join(base_url.chomp('/') + '/', 'greetings')
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  request = Net::HTTP::Post.new(uri)
  request['Content-Type'] = 'application/json'
  request['Idempotency-Key'] = idempotency_key
  # Monitoring/smoke traffic is tagged so it is isolated from real guest counts.
  request['X-Greeter-Synthetic'] = 'true'
  request.body = JSON.generate({ name: name })
  http.request(request)
end

Given('the deployed base URL from GREETER_BASE_URL') do
  @base_url = ENV.fetch('GREETER_BASE_URL')
end

When('I POST a greeting for {string} with a fresh idempotency key') do |name|
  @response = smoke_post(@base_url, name, SecureRandom.uuid)
end

Given('I POST a greeting for {string} with idempotency key {string}') do |name, key|
  @response = smoke_post(@base_url, name, key)
  @first_smoke_count = JSON.parse(@response.body).fetch('count')
end

When('I POST the same greeting again with idempotency key {string}') do |key|
  @response = smoke_post(@base_url, 'carol kay', key)
end

When('I POST a greeting with a body larger than the cap') do
  # Well-formed JSON whose name far exceeds the server's MAX_BODY_BYTES (8 KiB),
  # so the only reason to reject is size — a 413, not a 400/422.
  oversized = 'a' * (64 * 1024)
  @response = smoke_post(@base_url, oversized, SecureRandom.uuid)
end

Then('the HTTP status is {int}') do |status|
  expect(@response.code.to_i).to eq(status)
end

Then('the JSON body has a {string} of {int}') do |key, value|
  expect(JSON.parse(@response.body).fetch(key)).to eq(value)
end

Then('the JSON body {string} is a positive integer') do |key|
  value = JSON.parse(@response.body).fetch(key)
  expect(value).to be_a(Integer)
  expect(value).to be_positive
end

Then('the JSON body {string} is {string}') do |key, value|
  expect(JSON.parse(@response.body).fetch(key)).to eq(value)
end

Then('the JSON body {string} equals the first smoke response count') do |key|
  expect(JSON.parse(@response.body).fetch(key)).to eq(@first_smoke_count)
end

Then('the response body does not contain {string}') do |needle|
  expect(@response.body).not_to include(needle)
end
