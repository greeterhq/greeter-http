# frozen_string_literal: true

require 'spec_helper'
require 'json'
require_relative '../support/recording_http_server'
require_relative '../../perf/load'

# Red test for mark-smoke-and-load-traffic-synthetic (capability:
# synthetic-traffic), design D3. Load.run is called against a local recording
# server, so the real connection setup and threads are covered and a request
# that bypassed the shared helper would still be seen.
RSpec.describe 'GreeterHttp::Perf::Load' do
  let(:server) { RecordingHttpServer.new { [201, JSON.generate('count' => 1)] } }

  it 'marks every request it sends as synthetic',
     requirement: 'repository-tools-mark-deployed-stage-traffic-as-synthetic',
     scenario: 'deployed-load-generator-marks-every-request' do
    result = server.run do
      GreeterHttp::Perf::Load.run(base_url: server.base_url, vus: 2, duration_s: 1, rate: 10)
    end
    requests = server.requests

    expect(result[:failed]).to eq(0), "load run failed: #{result[:failure_reasons].inspect}"
    expect(requests).not_to be_empty
    expect(requests.map { |r| r.headers['x-greeter-synthetic'] }).to all(eq('true'))
  end
end
