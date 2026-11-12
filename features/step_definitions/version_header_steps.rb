# frozen_string_literal: true

# Steps for features/version_headers.feature. Reuses the deployed-URL, POST and
# status steps from smoke_steps.rb.

Then('the response header {string} is a plain dotted version without a leading {string}') do |name, prefix|
  value = @response[name]

  expect(value).not_to be_nil, "expected response header #{name} to be present"
  expect(value).to match(/\A\d+\.\d+\.\d+\z/)
  expect(value).not_to start_with(prefix)
end

Then('the response header {string} is present') do |name|
  value = @response[name]

  expect(value).not_to be_nil, "expected response header #{name} to be present"
  expect(value.strip).not_to be_empty
end
