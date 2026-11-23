# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

# Red tests for publish-prod-smoke-trace (capability: live-docs-traceability,
# requirement "A scheduled prod smoke publishes a trace").
#
# These specs parse .github/workflows/smoke-prod.yml (and ci.yml, for action
# refs) and assert the shape the OpenSpec scenarios require. They check
# structure only; a real green run against prod is verified after merge
# (tasks 3.5).
#
# Checks for references (`secrets.`, `vars.`, `github.event.`) read every string
# in the parsed YAML, so a YAML comment that mentions one does not count.
RSpec.describe 'Prod smoke workflow structure' do
  let(:workflows_dir) { File.expand_path('../../.github/workflows', __dir__) }
  let(:smoke) { YAML.safe_load_file(File.join(workflows_dir, 'smoke-prod.yml'), aliases: true) }
  let(:ci) { YAML.safe_load_file(File.join(workflows_dir, 'ci.yml'), aliases: true) }
  let(:jobs) { smoke.fetch('jobs') }
  let(:the_job) { jobs.values.first }
  let(:steps) { the_job.fetch('steps') }
  let(:trace_path) { 'tmp/repo-trace-smoke-prod.json' }
  let(:prod_url) { 'https://dhsuw1brrc.execute-api.eu-west-2.amazonaws.com' }
  let(:cucumber_command) { 'bundle exec cucumber --tags @smoke --format progress' }

  def condition(raw)
    raw.to_s.gsub(/\$\{\{|\}\}/, '').gsub(/\s+/, ' ').strip
  end

  def squish(text)
    text.to_s.split.join(' ')
  end

  # Every string key and value in a parsed YAML tree.
  def strings_in(node)
    case node
    when Hash then node.flat_map { |key, value| strings_in(key) + strings_in(value) }
    when Array then node.flat_map { |value| strings_in(value) }
    when String then [node]
    else []
    end
  end

  def runs
    steps.filter_map { |step| step['run'] }
  end

  def index_of_step(&block)
    idx = steps.index(&block)
    raise 'no matching step in smoke-prod.yml' if idx.nil?

    idx
  end

  def cucumber_index
    index_of_step { |step| step['run'].to_s.include?('cucumber') }
  end

  def upload_index
    index_of_step { |step| step['uses'].to_s.start_with?('actions/upload-artifact@') }
  end

  # action name => refs it is used at, across every job of a workflow.
  def action_refs(workflow)
    uses = workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps', []).filter_map { |s| s['uses'] } }
    uses.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |ref, refs|
      action, version = ref.split('@', 2)
      refs[action] << version
    end
  end

  it 'runs daily at 06:17 UTC, on demand, and after every completed CD run',
     requirement: 'a-scheduled-prod-smoke-publishes-a-trace',
     scenario: 'smoke-runs-daily-on-demand-and-after-cd' do
    triggers = smoke.fetch('on')

    expect(triggers.keys).to contain_exactly('schedule', 'workflow_dispatch', 'workflow_run')
    expect(triggers['schedule']).to eq([{ 'cron' => '17 6 * * *' }])
    expect(triggers['workflow_run']).to eq('workflows' => ['CD'], 'types' => ['completed'])
  end

  it 'has one job that runs only on main and not after a failed CD run',
     requirement: 'a-scheduled-prod-smoke-publishes-a-trace',
     scenario: 'job-runs-only-on-main-and-skips-a-failed-cd-run' do
    expect(jobs.size).to eq(1)
    expect(condition(the_job['if'])).to eq(
      "github.ref == 'refs/heads/main' && " \
      "(github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success')"
    )
  end

  it 'holds no credentials beyond a read-only token and reads no free-text event field',
     requirement: 'a-scheduled-prod-smoke-publishes-a-trace',
     scenario: 'workflow-holds-no-credentials' do
    strings = strings_in(smoke)

    expect(smoke['permissions']).to eq({ 'contents' => 'read' })
    jobs.each do |name, definition|
      expect(definition).not_to have_key('permissions'), "#{name} declares permissions"
    end
    expect(strings.grep(/\b(?:secrets|vars)\./)).to be_empty
    expect(steps.filter_map { |s| s['uses'] }.grep(%r{\Aaws-actions/})).to be_empty
    runs.each do |body|
      words = body.split(/[\s;&|()]+/)
      expect(words & %w[aws sam]).to be_empty, "a run step calls aws or sam: #{body.strip}"
    end
    expect(strings.flat_map { |s| s.scan(/github\.event\.[\w.]+/) }.uniq)
      .to eq(['github.event.workflow_run.conclusion'])
    expect(strings.grep(/github\.event\./)).to eq([the_job['if']])
  end

  it 'commits the prod base URL at the top level and never overrides it',
     requirement: 'a-scheduled-prod-smoke-publishes-a-trace',
     scenario: 'base-url-is-the-committed-prod-endpoint' do
    expect(smoke.fetch('env')['GREETER_BASE_URL']).to eq(prod_url)
    expect(the_job.fetch('env', {})).not_to have_key('GREETER_BASE_URL')
    steps.each do |step|
      expect(step.fetch('env', {})).not_to have_key('GREETER_BASE_URL'), "step overrides it: #{step['name']}"
    end
  end

  it 'checks out GITHUB_SHA without persisting the token, then sets up Ruby with the bundle cache',
     requirement: 'a-scheduled-prod-smoke-publishes-a-trace',
     scenario: 'smoke-checks-out-the-triggering-commit' do
    checkout, setup_ruby = steps.first(2)

    expect(checkout['uses']).to eq('actions/checkout@v5')
    expect(checkout.fetch('with', {})).not_to have_key('ref')
    expect(checkout.fetch('with', {})['persist-credentials']).to be(false)
    expect(setup_ruby['uses']).to eq('ruby/setup-ruby@v1')
    expect(setup_ruby.fetch('with', {})['bundler-cache']).to be(true)
  end

  it 'runs only the smoke scenarios and writes the prod trace',
     requirement: 'a-scheduled-prod-smoke-publishes-a-trace',
     scenario: 'cucumber-runs-only-smoke-scenarios-and-writes-the-trace' do
    cucumber_steps = steps.select { |step| step['run'].to_s.include?('cucumber') }

    expect(cucumber_steps.size).to eq(1)
    expect(squish(cucumber_steps.first['run'])).to eq(cucumber_command)
    expect(cucumber_steps.first.fetch('env', {})['REPO_TRACE_PATH']).to eq(trace_path)
  end

  it 'fails between cucumber and upload unless the version-headers smoke passed',
     requirement: 'a-scheduled-prod-smoke-publishes-a-trace',
     scenario: 'a-skipped-version-headers-smoke-fails-the-run' do
    jq_index = index_of_step { |step| step['run'].to_s.include?('jq -e') }
    body = steps[jq_index]['run']

    expect(jq_index).to be > cucumber_index
    expect(jq_index).to be < upload_index
    expect(body).to include(trace_path)
    expect(body).to include('.results')
    expect(body).to include('.requirement == "deployed-stage-exposes-version-headers"')
    expect(body).to include('.status == "passed"')
  end

  it 'uploads the trace as the last step, on success only',
     requirement: 'a-scheduled-prod-smoke-publishes-a-trace',
     scenario: 'trace-is-uploaded-only-after-a-passing-run' do
    upload = steps.last

    expect(upload['uses'].to_s).to start_with('actions/upload-artifact@')
    expect(upload.fetch('with')).to include(
      'name' => 'repo-trace-smoke-prod',
      'path' => trace_path,
      'retention-days' => 90,
      'if-no-files-found' => 'error'
    )
    expect(upload).not_to have_key('if')
  end

  it 'uses only actions that ci.yml uses, at the same refs',
     requirement: 'a-scheduled-prod-smoke-publishes-a-trace',
     scenario: 'actions-are-pinned-as-in-ci' do
    ci_refs = action_refs(ci)
    uses = steps.filter_map { |step| step['uses'] }

    expect(uses).not_to be_empty
    uses.each do |ref|
      action, version = ref.split('@', 2)
      expect(version).not_to be_nil, "#{ref} has no ref"
      expect(ci_refs.fetch(action, [])).to include(version), "#{ref} is not pinned as in ci.yml"
    end
  end

  it 'puts no expression in any run block',
     requirement: 'a-scheduled-prod-smoke-publishes-a-trace',
     scenario: 'run-blocks-contain-no-expressions' do
    expect(runs).not_to be_empty
    runs.each do |body|
      expect(body).not_to include('${{'), "run step contains an expression: #{body.strip}"
    end
  end
end
