# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require 'yaml'

# Contract checks on .github/workflows/ci.yml (and cd.yml) for publishing the
# repo trace, describing the API and guarding the release, one group per CI
# scenario of the live-docs-traceability and api-description capabilities.
# They read the YAML; behaviour itself is proven by a live run (tasks 3.6, 3.7).
# CI_WORKFLOW / CD_WORKFLOW point the spec at other files, to prove it can fail.
#
# Lookups that find nothing return {} / [] so a missing job or step is an
# expectation failure, not an exception.
RSpec.describe 'ci.yml contract' do
  let(:gate) do
    "github.event_name == 'schedule' || (github.event_name == 'push' && github.ref == 'refs/heads/main')"
  end
  let(:repo_root) { File.expand_path('../..', __dir__) }
  let(:workflow) { YAML.safe_load_file(ci_path, aliases: false) }
  let(:jobs) { workflow.fetch('jobs') }
  let(:cd_workflow) { YAML.safe_load_file(cd_path, aliases: false) }

  def ci_path
    ENV.fetch('CI_WORKFLOW', File.join(repo_root, '.github', 'workflows', 'ci.yml'))
  end

  def cd_path
    ENV.fetch('CD_WORKFLOW', File.join(repo_root, '.github', 'workflows', 'cd.yml'))
  end

  def job(name)
    jobs.fetch(name, {})
  end

  def job_steps(name)
    job(name)['steps'] || []
  end

  def step_matches?(step, uses:, run:, artifact:)
    [uses.nil? || step['uses'].to_s.start_with?(uses),
     run.nil? || step['run'].to_s.include?(run),
     artifact.nil? || step.dig('with', 'name') == artifact].all?
  end

  def find_step(name, uses: nil, run: nil, artifact: nil)
    job_steps(name).find { |step| step_matches?(step, uses: uses, run: run, artifact: artifact) } || {}
  end

  def step_env(name, step)
    (job(name)['env'] || {}).merge(step['env'] || {})
  end

  # `${{ expr }}` and plain expressions compare equal once wrapped and spaced alike.
  def condition(raw)
    raw.to_s.gsub(/\$\{\{|\}\}/, '').gsub(/\s+/, ' ').strip
  end

  def needs_of(name)
    Array(job(name)['needs'])
  end

  # The unit-test rspec step of `functional` (not the DynamoDB integration run).
  def unit_rspec_step
    job_steps('functional').find do |step|
      step['run'].to_s.include?('bundle exec rspec') && !step['run'].to_s.include?('spec/integration')
    end || {}
  end

  def cucumber_step
    find_step('functional', run: 'bundle exec cucumber')
  end

  def merge_step
    find_step('functional', run: 'bin/merge-repo-trace')
  end

  def upload_step
    find_step('functional', uses: 'actions/upload-artifact', artifact: 'repo-trace')
  end

  # Position of a step in its job, or -1 when it is not there (so an "after"
  # comparison fails instead of raising).
  def step_index(name, step)
    job_steps(name).index(step) || -1
  end

  # The rspec arguments of a `bundle exec rspec ...` line, with any --out path
  # redirected so the dry run never overwrites the real HTML report.
  def dry_run_args(run, html_path)
    args = Shellwords.split(run).drop_while { |word| word != 'rspec' }.drop(1)
    args.each_with_index.map { |arg, index| index.positive? && args[index - 1] == '--out' ? html_path : arg }
  end

  describe 'functional job traces',
           requirement: 'ci-publishes-the-trace-on-main-and-weekly',
           scenario: 'functional-job-writes-and-merges-both-traces' do
    it 'runs rspec with RepoTraceFormatter and REPO_TRACE_PATH=tmp/repo-trace-spec.json', :aggregate_failures do
      step = unit_rspec_step

      expect(step['run']).to include('--format RepoTraceFormatter')
      expect(step_env('functional', step)['REPO_TRACE_PATH']).to eq('tmp/repo-trace-spec.json')
    end

    it 'runs cucumber with REPO_TRACE_PATH=tmp/repo-trace-bdd.json' do
      expect(step_env('functional', cucumber_step)['REPO_TRACE_PATH']).to eq('tmp/repo-trace-bdd.json')
    end

    it 'merges both traces after both test steps, on every event', :aggregate_failures do
      step = merge_step

      expect(step['run'].to_s.split.join(' '))
        .to include('bin/merge-repo-trace tmp/repo-trace.json tmp/repo-trace-spec.json tmp/repo-trace-bdd.json')
      expect(step).not_to include('if')
      expect(step_index('functional', step)).to be > step_index('functional', unit_rspec_step)
      expect(step_index('functional', step)).to be > step_index('functional', cucumber_step)
    end

    it 'runs the rspec command with a formatter that resolves and selects examples', :aggregate_failures do
      Dir.mktmpdir('ci-dry-run') do |dir|
        args = dry_run_args(unit_rspec_step['run'].to_s, File.join(dir, 'rspec.html'))
        expect(args.each_cons(2)).to include(%w[--format RepoTraceFormatter])

        out, err, = Open3.capture3({ 'REPO_TRACE_PATH' => File.join(dir, 'trace.json') },
                                   RbConfig.ruby, Gem.bin_path('rspec-core', 'rspec'), *args, '--dry-run',
                                   chdir: repo_root)
        expect(out[/(\d+) examples?/, 1].to_i).to be_positive
        expect(out + err).not_to match(/No examples found|RepoTraceFormatter/)
      end
    end
  end

  describe 'publishing the trace',
           requirement: 'ci-publishes-the-trace-on-main-and-weekly',
           scenario: 'trace-is-uploaded-only-on-main-and-weekly' do
    it 'runs weekly at 17 6 * * 1' do
      expect(workflow.fetch('on').fetch('schedule', [])).to include('cron' => '17 6 * * 1')
    end

    it 'uploads repo-trace for 90 days and fails if the file is missing', :aggregate_failures do
      expect(upload_step['with'])
        .to include('path' => 'tmp/repo-trace.json', 'retention-days' => 90, 'if-no-files-found' => 'error')
    end

    it 'uploads only after the merge, only on main pushes and the schedule, and only after a green run',
       :aggregate_failures do
      step = upload_step

      expect(condition(step['if'])).to eq(gate)
      expect(condition(step['if'])).not_to match(/always\(\)|failure\(\)|cancelled\(\)/)
      expect(step).not_to include('continue-on-error')
      expect(step_index('functional', step)).to be > step_index('functional', merge_step)
    end
  end

  describe 'notify-docs',
           requirement: 'ci-publishes-the-trace-on-main-and-weekly',
           scenario: 'notify-docs-dispatches-docs-refresh' do
    let(:mint) { find_step('notify-docs', uses: 'actions/create-github-app-token@v3') }
    let(:dispatch) { find_step('notify-docs', run: 'gh api') }

    it 'needs functional, has no token rights and uses the same gate', :aggregate_failures do
      expect(needs_of('notify-docs')).to eq(['functional'])
      expect(job('notify-docs')['permissions']).to eq({})
      expect(condition(job('notify-docs')['if'])).to eq(gate)
    end

    it 'mints an App token for greeterhq/greeter-docs only' do
      expect(mint['with']).to include('client-id' => '${{ vars.DISPATCH_APP_CLIENT_ID }}',
                                      'private-key' => '${{ secrets.DISPATCH_APP_PRIVATE_KEY }}',
                                      'owner' => 'greeterhq', 'repositories' => 'greeter-docs')
    end

    it 'sends docs-refresh to greeter-docs with client_payload[repo]=greeter-http' do
      expect(dispatch['run']).to include('repos/greeterhq/greeter-docs/dispatches', 'event_type=docs-refresh',
                                         'client_payload[repo]=greeter-http')
    end
  end

  describe 'credentials',
           requirement: 'ci-publishes-the-trace-on-main-and-weekly',
           scenario: 'workflow-credentials-are-least-privilege' do
    let(:mint) { find_step('notify-docs', uses: 'actions/create-github-app-token@v3') }
    let(:dispatch) { find_step('notify-docs', run: 'gh api') }

    # The steps that handle the trace, plus the notify-docs and api-diff scripts.
    def trace_and_dispatch_scripts
      functional = job_steps('functional').select do |step|
        step_env('functional', step).key?('REPO_TRACE_PATH') || step['run'].to_s.include?('repo-trace')
      end
      (functional + job_steps('notify-docs') + job_steps('api-diff')).map { |step| step['run'].to_s }
    end

    it 'sets top-level permissions to exactly contents: read' do
      expect(workflow['permissions']).to eq('contents' => 'read')
    end

    it 'grants write only in release and bump-core, and nothing in notify-docs', :aggregate_failures do
      writers = jobs.select { |_name, definition| (definition['permissions'] || {}).values.include?('write') }

      expect(writers.keys).to contain_exactly('release', 'bump-core')
      expect(job('notify-docs')['permissions']).to eq({})
    end

    it 'requests only permission-contents: write and never skips token revocation', :aggregate_failures do
      expect(mint['with'].to_h.keys.grep(/\Apermission-/)).to eq(['permission-contents'])
      expect(mint.dig('with', 'permission-contents')).to eq('write')
      expect(mint.fetch('with', {})).not_to include('skip-token-revoke')
    end

    it 'mints the token in the step directly before the dispatch and exposes it to no other job' do
      steps = job_steps('notify-docs')
      mint_index = steps.index(mint)

      expect(mint_index).not_to be_nil
      expect(steps.index(dispatch)).to eq(mint_index + 1)
      expect(job('notify-docs')).not_to include('outputs')
    end

    it 'passes the minted token to gh only as GH_TOKEN in env' do
      expect(dispatch['env']).to eq('GH_TOKEN' => "${{ steps.#{mint['id']}.outputs.token }}")
    end

    it 'interpolates no expression into a run: script of the trace steps, notify-docs or api-diff',
       :aggregate_failures do
      scripts = trace_and_dispatch_scripts

      expect(scripts).not_to be_empty
      expect(scripts.grep(/\$\{\{/)).to be_empty
    end
  end

  describe 'concurrency',
           requirement: 'ci-publishes-the-trace-on-main-and-weekly',
           scenario: 'runs-on-main-and-weekly-runs-always-finish' do
    it 'groups by event and ref and cancels only superseded pull request runs', :aggregate_failures do
      expect(workflow.dig('concurrency', 'group')).to eq('ci-${{ github.event_name }}-${{ github.ref }}')
      expect(workflow.dig('concurrency', 'cancel-in-progress')).to eq("${{ github.event_name == 'pull_request' }}")
    end
  end

  describe 'scheduled runs',
           requirement: 'ci-publishes-the-trace-on-main-and-weekly',
           scenario: 'scheduled-run-creates-no-release-or-deployment' do
    it 'gates the upload and notify-docs away from pull requests, tag pushes and dispatches', :aggregate_failures do
      expect(gate).not_to include('pull_request', 'repository_dispatch', 'refs/tags')
      expect(condition(upload_step['if'])).to eq(gate)
      expect(condition(job('notify-docs')['if'])).to eq(gate)
    end

    it 'releases only for a v* tag ref and bumps greeter-core only on its dispatch', :aggregate_failures do
      expect(condition(job('release')['if'])).to eq("startsWith(github.ref, 'refs/tags/v')")
      expect(condition(job('bump-core')['if'])).to include("github.event_name == 'repository_dispatch'")
    end

    it 'lets a scheduled run start the validation jobs', :aggregate_failures do
      expect(workflow.fetch('on').fetch('schedule', [])).not_to be_empty
      expect(condition(job('lint')['if'])).to eq("github.event_name != 'repository_dispatch'")
    end

    it 'runs cd.yml only on the deploy-release dispatch', :aggregate_failures do
      triggers = cd_workflow.fetch('on')

      expect(triggers.keys).to eq(['repository_dispatch'])
      expect(triggers.dig('repository_dispatch', 'types')).to eq(['deploy-release'])
    end
  end

  describe 'the old traceability report',
           requirement: 'ci-publishes-the-trace-on-main-and-weekly',
           scenario: 'the-old-traceability-report-is-gone' do
    it 'has no support file and no upload of tmp/traceability.json', :aggregate_failures do
      expect(File).not_to exist(File.join(repo_root, 'features', 'support', 'traceability.rb'))
      text = File.read(ci_path)
      expect(text).not_to include('traceability-report')
      expect(text).not_to include('tmp/traceability.json')
    end
  end

  describe 'api-diff',
           requirement: 'breaking-changes-to-openapi-yaml-fail-pull-requests',
           scenario: 'the-comparison-is-configured-as-specified' do
    let(:presence) { job_steps('api-diff').find { |step| step['run'].to_s.include?('git cat-file') } || {} }
    let(:oasdiff) { find_step('api-diff', uses: 'oasdiff/oasdiff-action/breaking@v0') }

    it 'runs only for pull requests, with read-only contents', :aggregate_failures do
      expect(condition(job('api-diff')['if'])).to eq("github.event_name == 'pull_request'")
      expect(job('api-diff')['permissions']).to eq('contents' => 'read')
    end

    it 'checks out the full history without persisting credentials' do
      expect(find_step('api-diff', uses: 'actions/checkout@v5')['with'])
        .to include('fetch-depth' => 0, 'persist-credentials' => false)
    end

    it 'compares origin/<base>:openapi.yaml with HEAD:openapi.yaml, failing at level ERR', :aggregate_failures do
      expect(oasdiff['with']).to include('base' => 'origin/${{ github.base_ref }}:openapi.yaml',
                                         'revision' => 'HEAD:openapi.yaml', 'fail-on' => 'ERR')
      expect([false, 'false']).to include(oasdiff.dig('with', 'review'))
    end

    it 'passes the base ref to the script only through env', :aggregate_failures do
      expect(presence.dig('env', 'BASE_REF')).to eq('${{ github.base_ref }}')
      expect(presence['run']).to include('${BASE_REF}')
      expect(job_steps('api-diff').map { |step| step['run'].to_s }.grep(/\$\{\{/)).to be_empty
    end
  end

  describe 'a base without openapi.yaml',
           requirement: 'breaking-changes-to-openapi-yaml-fail-pull-requests',
           scenario: 'a-base-without-openapi-yaml-skips-the-comparison' do
    let(:presence) { job_steps('api-diff').find { |step| step['run'].to_s.include?('git cat-file') } || {} }
    let(:oasdiff) { find_step('api-diff', uses: 'oasdiff/oasdiff-action/breaking@v0') }

    it 'checks whether the base branch has the file and records the answer as the output present',
       :aggregate_failures do
      expect(presence['run']).to include('git cat-file -e', 'openapi.yaml', 'present=true', 'present=false',
                                         'GITHUB_OUTPUT')
      expect(presence['id']).not_to be_nil
      expect(presence).not_to include('if')
    end

    it 'runs the comparison only when the base has the file' do
      expect(condition(oasdiff['if'])).to eq("steps.#{presence['id']}.outputs.present == 'true'")
    end
  end

  describe 'the release job and openapi.yaml',
           requirement: 'releases-carry-the-description',
           scenario: 'the-tarball-includes-openapi-yaml' do
    it 'copies openapi.yaml into the package directory before the tar step' do
      steps = job_steps('release')
      tar_index = steps.index { |step| step['run'].to_s.include?('tar -czf') }

      expect(tar_index).not_to be_nil
      scripts = steps.first(tar_index + 1).map { |step| step['run'].to_s }.join("\n")
      expect(scripts).to match(%r{cp [^\n]*openapi\.yaml[^\n]*dist/\$\{pkg\}})
      expect(scripts.index('openapi.yaml')).to be < scripts.index('tar -czf')
    end
  end

  describe 'the release bundle check',
           requirement: 'every-response-of-the-composed-app-matches-openapi-yaml',
           scenario: 'the-lambda-bundle-stays-free-of-the-test-gem' do
    it 'fails the release when .aws-sam/build contains an openapi_first-* directory', :aggregate_failures do
      steps = job_steps('release')
      build_index = steps.index { |step| step['run'].to_s.include?('sam build') }
      check = steps.each_with_index.find do |step, index|
        build_index && index > build_index && step['run'].to_s.include?('openapi_first-')
      end&.first || {}

      expect(build_index).not_to be_nil
      expect(check['run']).to include('.aws-sam/build', 'openapi_first-', 'exit 1')
    end

    # setup-ruby's bundler-cache installs every group into ./vendor/bundle, and
    # sam build copies the source tree, so the CI bundle must be gone first.
    it 'removes the CI bundle before sam build, after every bundle exec step', :aggregate_failures do
      steps = job_steps('release')
      build_index = steps.index { |step| step['run'].to_s.include?('sam build') }
      removal_index = steps.index { |step| step['run'].to_s.match?(%r{rm -rf vendor/bundle \.bundle}) }
      last_exec_index = steps.rindex { |step| step['run'].to_s.include?('bundle exec') }

      expect(removal_index).not_to be_nil
      expect(build_index).not_to be_nil
      expect(removal_index).to be < build_index
      expect(last_exec_index).to be < removal_index
    end
  end
end
