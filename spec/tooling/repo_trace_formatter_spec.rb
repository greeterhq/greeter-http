# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# Runs fixture example files in a separate rspec process with RepoTraceFormatter
# and reads the trace it writes. --options /dev/null keeps this repo's .rspec
# (and spec_helper) out of the child run, so the child loads only the formatter.
RSpec.describe 'RepoTraceFormatter' do
  let(:repo_root) { File.expand_path('../..', __dir__) }
  let(:formatter) { File.join(repo_root, 'spec', 'support', 'repo_trace_formatter.rb') }
  let(:sha) { '0123456789abcdef0123456789abcdef01234567' }
  let(:base_env) { { 'GITHUB_SHA' => sha, 'GITHUB_RUN_ID' => '4242' } }
  let(:result_keys) { %w[requirement scenario status source location] }

  let(:workdir) { Dir.mktmpdir('repo-trace') }
  let(:trace_path) { File.join(workdir, 'trace.json') }

  after { FileUtils.remove_entry(workdir) }

  def run_fixture(name, env: {})
    command = [RbConfig.ruby, Gem.bin_path('rspec-core', 'rspec'), '--options', File::NULL,
               '--require', formatter, '--format', 'RepoTraceFormatter',
               "spec/fixtures/repo_trace/#{name}.rb"]
    child_env = base_env.merge('REPO_TRACE_PATH' => trace_path).merge(env)
    Open3.capture3(child_env, *command, chdir: repo_root)
  end

  def trace
    JSON.parse(File.read(trace_path))
  end

  def result_for(scenario)
    trace.fetch('results').find { |result| result['scenario'] == scenario }
  end

  describe 'the v1 document',
           requirement: 'repo-trace-contains-only-slugs-statuses-locations-and-run-metadata',
           scenario: 'formatter-writes-the-v1-document' do
    before { run_fixture('statuses') }

    it 'writes the v1 top-level fields', :aggregate_failures do
      expect(trace.keys).to match_array(%w[schema repo sha recorded_at run_id results])
      expect(trace).to include('schema' => 'greeterhq.repo-trace.v1', 'repo' => 'greeter-http',
                               'sha' => sha, 'run_id' => '4242')
      expect(trace['recorded_at']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it 'records passed and failed examples with source rspec and a spec location', :aggregate_failures do
      expect(result_for('passing-scenario')).to include('status' => 'passed', 'source' => 'rspec',
                                                        'requirement' => 'fixture-requirement')
      expect(result_for('failing-scenario')).to include('status' => 'failed', 'source' => 'rspec')
      expect(result_for('passing-scenario')['location']).to eq('spec/fixtures/repo_trace/statuses.rb:7')
      expect(result_for('failing-scenario')['location']).to eq('spec/fixtures/repo_trace/statuses.rb:11')
    end

    it 'records only examples tagged with both a requirement and a scenario' do
      expect(trace['results'].map { |result| result['scenario'] })
        .to contain_exactly('passing-scenario', 'failing-scenario', 'skipped-scenario', 'pending-scenario')
    end

    it 'sorts results by location' do
      locations = trace['results'].map { |result| result['location'] }

      expect(locations).to eq(locations.sort_by { |location| [location[/\A[^:]+/], location[/\d+\z/].to_i] })
    end

    it 'falls back to git rev-parse HEAD and a null run_id outside GitHub Actions', :aggregate_failures do
      head, = Open3.capture2('git', 'rev-parse', 'HEAD', chdir: repo_root)
      run_fixture('plain', env: { 'GITHUB_SHA' => nil, 'GITHUB_RUN_ID' => nil })

      expect(trace['sha']).to eq(head.strip)
      expect(trace['run_id']).to be_nil
    end

    it 'collapses shared-example results with the same location to the worst status' do
      run_fixture('shared')

      expect(trace['results']).to contain_exactly(include('scenario' => 'shared-scenario', 'status' => 'failed'))
    end
  end

  describe 'skip and pending',
           requirement: 'repo-trace-contains-only-slugs-statuses-locations-and-run-metadata',
           scenario: 'skipped-and-pending-are-told-apart' do
    before { run_fixture('statuses') }

    it 'records a skipped example as skipped and a pending example as pending', :aggregate_failures do
      expect(result_for('skipped-scenario')['status']).to eq('skipped')
      expect(result_for('pending-scenario')['status']).to eq('pending')
    end
  end

  describe 'malformed values',
           requirement: 'repo-trace-contains-only-slugs-statuses-locations-and-run-metadata',
           scenario: 'writers-refuse-malformed-values' do
    it 'refuses a requirement that is not a slug, without echoing it, and writes no file', :aggregate_failures do
      out, err, status = run_fixture('malformed')

      expect(status).not_to be_success
      expect(out + err).to include('invalid requirement')
      expect(out + err).not_to include('Alice Smith')
      expect(File).not_to exist(trace_path)
    end

    { 'GITHUB_SHA' => %w[sha not-a-sha], 'GITHUB_RUN_ID' => %w[run_id 12a] }.each do |variable, (field, value)|
      it "refuses a #{variable} of the wrong shape and writes no file", :aggregate_failures do
        out, err, status = run_fixture('plain', env: { variable => value })

        expect(status).not_to be_success
        expect(out + err).to include("invalid #{field}")
        expect(File).not_to exist(trace_path)
      end
    end
  end

  describe 'privacy',
           requirement: 'repo-trace-contains-only-slugs-statuses-locations-and-run-metadata',
           scenario: 'writers-omit-descriptions' do
    before { run_fixture('statuses') }

    it 'never writes example descriptions', :aggregate_failures do
      expect(File.read(trace_path)).not_to include('Alice')
      expect(trace['results']).to all(satisfy { |result| result.keys.sort == result_keys.sort })
    end
  end
end
