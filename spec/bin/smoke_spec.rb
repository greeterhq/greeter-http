# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'
require_relative '../support/recording_http_server'

# Red test for mark-smoke-and-load-traffic-synthetic (capability:
# synthetic-traffic), design D2. bin/smoke calls `exit` and `abort` at load
# time, so it runs as a subprocess against a local recording server. Exit 0
# proves both checks ran, so every request the script makes was recorded.
RSpec.describe 'bin/smoke' do
  let(:repo_root) { File.expand_path('../..', __dir__) }
  let(:script) { File.join(repo_root, 'bin', 'smoke') }

  # A valid greeting gets 201 with an increasing count. A body that isn't valid
  # JSON gets 400, as the real service answers.
  let(:server) do
    count = 0
    RecordingHttpServer.new do |request|
      JSON.parse(request.body)
      count += 1
      [201, JSON.generate('count' => count)]
    rescue JSON::ParserError
      [400, JSON.generate('error' => 'malformed_json')]
    end
  end

  def run_smoke(base_url)
    env = { 'GREETER_BASE_URL' => base_url, 'no_proxy' => '127.0.0.1', 'NO_PROXY' => '127.0.0.1' }
    Open3.capture3(env, RbConfig.ruby, script, chdir: repo_root)
  end

  it 'marks every request it sends as synthetic',
     requirement: 'repository-tools-mark-deployed-stage-traffic-as-synthetic',
     scenario: 'post-deploy-smoke-script-marks-every-request' do
    out, err, status = server.run { run_smoke(server.base_url) }
    requests = server.requests

    expect(status.exitstatus).to eq(0), "bin/smoke exited #{status.exitstatus}\n#{out}#{err}"
    expect(requests.size).to eq(3)
    expect(requests.map { |r| r.headers['x-greeter-synthetic'] }).to all(eq('true'))
  end
end
