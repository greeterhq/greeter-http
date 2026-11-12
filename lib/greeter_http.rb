# frozen_string_literal: true

require 'greeter/core'

# greeter-http: exposes greeter-core over HTTP (AWS Lambda + API Gateway) with a
# per-guest greeting count persisted in DynamoDB.
#
# Hexagonal layout:
#   application/ - use cases composing Greeter::Core
#   ports/       - abstract interfaces local to this service
#   adapters/    - all I/O (DynamoDB, Lambda, Rack, clock, presenter)
#   app.rb       - the ONLY composition root
module GreeterHttp
  module Application; end
  module Ports; end
  module Adapters; end
end

# Version constant.
require 'greeter_http/version'

# Ports (abstract interfaces).
require 'greeter_http/ports/greeting_counter'

# Values.
require 'greeter_http/application/greeted_guest'

# Application use cases.
require 'greeter_http/application/greet_and_count'

# Adapters (all I/O).
require 'greeter_http/adapters/in_memory_greeting_counter'
require 'greeter_http/adapters/dynamodb_greeting_counter'
require 'greeter_http/adapters/system_clock'
require 'greeter_http/adapters/json_presenter'
require 'greeter_http/adapters/rack_app'
require 'greeter_http/adapters/version_headers'
require 'greeter_http/adapters/lambda_handler'

# Composition root.
require 'greeter_http/app'
