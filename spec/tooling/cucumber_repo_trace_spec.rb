# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# Runs fixture features in a separate cucumber process with only the repo-trace
# writer (features/support/repo_trace.rb) and fixture steps loaded. The child
# runs inside spec/fixtures/repo_trace_cucumber so its scenario locations are
# features/<file>:<line>, as in the real run.
RSpec.describe 'Cucumber repo-trace writer' do
  let(:repo_root) { File.expand_path('../..', __dir__) }
  let(:fixture_root) { File.join(repo_root, 'spec', 'fixtures', 'repo_trace_cucumber') }
  let(:writer) { File.join(repo_root, 'features', 'support', 'repo_trace.rb') }
  let(:sha) { 'fedcba9876543210fedcba9876543210fedcba98' }
  let(:workdir) { Dir.mktmpdir('repo-trace-bdd') }
  let(:trace_path) { File.join(workdir, 'trace.json') }
  let(:result_keys) { %w[requirement scenario status source location] }

  after { FileUtils.remove_entry(workdir) }

  def run_feature(name, env: {})
    command = [RbConfig.ruby, Gem.bin_path('cucumber', 'cucumber'), '--no-profile', '--format', 'progress',
               '--require', writer, '--require', 'features/step_definitions/steps.rb',
               "features/#{name}.feature"]
    child_env = {
      'BUNDLE_GEMFILE' => File.join(repo_root, 'Gemfile'), 'CUCUMBER_PUBLISH_QUIET' => 'true',
      'GITHUB_SHA' => sha, 'GITHUB_RUN_ID' => '777', 'REPO_TRACE_PATH' => trace_path
    }.merge(env)
    Open3.capture3(child_env, *command, chdir: fixture_root)
  end

  def trace
    JSON.parse(File.read(trace_path))
  end

  def result_for(scenario)
    trace.fetch('results').find { |result| result['scenario'] == scenario }
  end

  describe 'the v1 document',
           requirement: 'repo-trace-contains-only-slugs-statuses-locations-and-run-metadata',
           scenario: 'cucumber-writer-writes-the-v1-document' do
    before { run_feature('statuses') }

    it 'writes the v1 top-level fields', :aggregate_failures do
      expect(trace.keys).to match_array(%w[schema repo sha recorded_at run_id results])
      expect(trace).to include('schema' => 'greeterhq.repo-trace.v1', 'repo' => 'greeter-http',
                               'sha' => sha, 'run_id' => '777')
      expect(trace['recorded_at']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it 'records passed and failed scenarios with source cucumber at their Scenario: line', :aggregate_failures do
      expect(result_for('passing-scenario')).to include('requirement' => 'fixture-requirement', 'status' => 'passed',
                                                        'source' => 'cucumber',
                                                        'location' => 'features/statuses.feature:4')
      expect(result_for('failing-scenario')).to include('status' => 'failed', 'source' => 'cucumber',
                                                        'location' => 'features/statuses.feature:8')
    end

    it 'records only scenarios tagged with both a requirement and a scenario' do
      expect(trace['results'].map { |result| result['scenario'] })
        .to contain_exactly('passing-scenario', 'failing-scenario', 'pending-scenario', 'skipped-scenario')
    end
  end

  describe 'pending and skipped',
           requirement: 'repo-trace-contains-only-slugs-statuses-locations-and-run-metadata',
           scenario: 'skipped-and-pending-are-told-apart' do
    before { run_feature('statuses') }

    it 'records a pending scenario as pending and a skipped scenario as skipped', :aggregate_failures do
      expect(result_for('pending-scenario')['status']).to eq('pending')
      expect(result_for('skipped-scenario')['status']).to eq('skipped')
    end
  end

  describe 'malformed values',
           requirement: 'repo-trace-contains-only-slugs-statuses-locations-and-run-metadata',
           scenario: 'writers-refuse-malformed-values' do
    it 'refuses a requirement tag that is not a slug, without echoing it, and writes no file', :aggregate_failures do
      out, err, status = run_feature('malformed')

      expect(status).not_to be_success
      expect(out + err).to include('invalid requirement')
      expect(out + err).not_to include('BadSlugValue')
      expect(File).not_to exist(trace_path)
    end

    { 'GITHUB_SHA' => %w[sha not-a-sha], 'GITHUB_RUN_ID' => %w[run_id 12a] }.each do |variable, (field, value)|
      it "refuses a #{variable} of the wrong shape and writes no file", :aggregate_failures do
        out, err, = run_feature('plain', env: { variable => value })

        expect(out + err).to include("invalid #{field}")
        expect(File).not_to exist(trace_path)
      end
    end
  end

  describe 'privacy',
           requirement: 'repo-trace-contains-only-slugs-statuses-locations-and-run-metadata',
           scenario: 'writers-omit-descriptions' do
    before { run_feature('statuses') }

    it 'never writes scenario names or step text', :aggregate_failures do
      expect(File.read(trace_path)).not_to include('Alice')
      expect(trace['results']).to all(satisfy { |result| result.keys.sort == result_keys.sort })
    end
  end
end
