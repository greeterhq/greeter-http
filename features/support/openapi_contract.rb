# frozen_string_literal: true

# Cucumber loads every file in features/support, after env.rb. This one loads the
# same support as RSpec (spec/support/openapi_contract.rb), so a response that
# does not match openapi.yaml fails the scenario that produced it.
require_relative '../../spec/support/openapi_contract'
