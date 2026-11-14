# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

# Red tests for adopt-acceptance-gate (capability: acceptance-gated-release).
#
# These specs parse .github/workflows/cd.yml and ci.yml and assert the shape the
# OpenSpec scenarios require: job order and `needs`, `if` conditions,
# permissions, the gate call, the restore job and the announce jobs. They check
# structure only; behaviour that needs GitHub (the gate really running, the
# ledger really updating) is verified on the first real release (tasks 4.6).
#
# Each example carries `requirement:` and `scenario:` metadata holding the slugs
# of the OpenSpec headings. Examples without them are checks recorded in
# design.md (security findings S12 to S16) that are not scenarios.
RSpec.describe 'CD workflow structure' do
  let(:workflows_dir) { File.expand_path('../../.github/workflows', __dir__) }
  let(:cd) { YAML.safe_load_file(File.join(workflows_dir, 'cd.yml'), aliases: true) }
  let(:ci) { YAML.safe_load_file(File.join(workflows_dir, 'ci.yml'), aliases: true) }
  let(:jobs) { cd.fetch('jobs') }

  GATE_USES = 'greeterhq/greeter-acceptance/.github/workflows/gate.yml@v0.2.2'
  RESTORE_IF = "always() && needs.deploy-dev.result == 'success' && needs.gate.result == 'failure'"
  NEW_JOBS = %w[resolve gate restore-dev announce-stage announce-prod].freeze

  def job(name)
    jobs.fetch(name) { raise "cd.yml has no job #{name.inspect}" }
  end

  def needs(name)
    Array(job(name)['needs'])
  end

  # Every job a job depends on, directly or not.
  def needs_closure(name, seen = [])
    needs(name).each do |dep|
      next if seen.include?(dep)

      seen << dep
      needs_closure(dep, seen)
    end
    seen
  end

  def steps(name)
    job(name).fetch('steps')
  end

  def runs(name)
    steps(name).filter_map { |s| s['run'] }
  end

  def index_of_step(name, &block)
    idx = steps(name).index(&block)
    raise "no matching step in #{name}" if idx.nil?

    idx
  end

  def condition(raw)
    raw.to_s.gsub(/\$\{\{|\}\}/, '').gsub(/\s+/, ' ').strip
  end

  describe 'release tag resolution' do
    it 'outputs the tag and the commit sha before dev is deployed',
       requirement: 'release-tag-is-validated-and-resolved-before-any-deployment',
       scenario: 'valid-tag-resolves-to-its-commit' do
      resolve = job('resolve')

      expect(resolve['permissions']).to eq({ 'contents' => 'read' })
      expect(resolve.fetch('outputs').keys).to include('tag', 'sha')
      body = runs('resolve').join("\n")
      expect(body).to include('gh api')
      expect(body).to include('commits/')
      expect(body).to include('--jq .sha')
      expect(body).to include('[0-9a-f]{40}')
      step_env = steps('resolve').filter_map { |s| s['env'] }.reduce({}, :merge)
      expect(step_env.values.join(' ')).to include('github.event.client_payload.tag')
      expect(needs('deploy-dev')).to include('resolve')
      expect(YAML.dump(job('deploy-dev'))).to include('needs.resolve.outputs.tag')
      expect(YAML.dump(job('deploy-dev'))).not_to include('client_payload')
    end

    it 'fails at resolve for a malformed tag, before anything else can run',
       requirement: 'release-tag-is-validated-and-resolved-before-any-deployment',
       scenario: 'malformed-tag-stops-the-run' do
      body = runs('resolve').join("\n")
      check_at = body.index('[0-9]+\.[0-9]+\.[0-9]+')
      lookup_at = body.index('gh api')

      expect(needs('resolve')).to be_empty
      expect(check_at).not_to be_nil
      expect(body).to include('exit 1')
      expect(check_at).to be < lookup_at
      (jobs.keys - ['resolve']).each do |name|
        expect(needs_closure(name)).to include('resolve'), "#{name} does not depend on resolve"
      end
    end

    it 'never echoes the tag as workflow-command text',
       requirement: 'release-tag-is-validated-and-resolved-before-any-deployment',
       scenario: 'hostile-tag-text-is-not-echoed' do
      lines = runs('resolve').join("\n").lines

      lines.select { |l| l.include?('::') }.each do |line|
        expect(line).not_to match(/\bTAG\b|\btag\b/), "workflow command mentions the tag: #{line.strip}"
      end
      printed = lines.select { |l| l =~ /\b(echo|printf)\b/ && l =~ /\bTAG\b/ }
      expect(printed.reject { |l| l.include?('GITHUB_OUTPUT') }).to be_empty
    end
  end

  describe 'token permissions' do
    it 'grants nothing by default and has every job declare its own',
       requirement: 'workflow-token-permissions-are-explicit',
       scenario: 'default-none-every-job-declares' do
      expect(cd['permissions']).to eq({})
      jobs.each do |name, definition|
        expect(definition).to have_key('permissions'), "#{name} declares no permissions"
      end
    end
  end

  describe 'the acceptance gate' do
    it 'runs for channel http against stage after a successful dev deployment',
       requirement: 'dev-deployment-is-gated-by-the-acceptance-suite',
       scenario: 'gate-runs-after-a-successful-dev-deployment' do
      gate = job('gate')

      expect(gate['uses']).to eq(GATE_USES)
      expect(needs('gate')).to include('resolve', 'deploy-dev')
      expect(gate).not_to have_key('if')
      expect(gate['with']).to include(
        'acceptance_ref' => 'v0.2.2',
        'channel' => 'http',
        'candidate_version' => '${{ needs.resolve.outputs.tag }}',
        'candidate_sha' => '${{ needs.resolve.outputs.sha }}',
        'environment' => 'stage'
      )
    end

    it 'is given no URL, host or secrets, so the target comes from the suite configuration',
       requirement: 'dev-deployment-is-gated-by-the-acceptance-suite',
       scenario: 'gate-target-is-not-supplied-by-the-pipeline' do
      gate = job('gate')

      expect(gate['with'].keys).to contain_exactly(
        'acceptance_ref', 'channel', 'candidate_version', 'candidate_sha', 'environment'
      )
      expect(gate['with'].keys.grep(/url|host|base|target|endpoint/i)).to be_empty
      expect(YAML.dump(gate['with'])).not_to match(%r{https?://})
      expect(gate).not_to have_key('secrets')
    end

    # S16: the gate runs suite code with this repository's token.
    it 'holds exactly contents: read' do
      expect(job('gate')['permissions']).to eq({ 'contents' => 'read' })
    end
  end

  describe 'promotion to prod' do
    it 'cannot start, or ask for approval, when the gate did not pass',
       requirement: 'a-failed-gate-stops-promotion-to-prod',
       scenario: 'gate-failure-blocks-prod' do
      prod = job('deploy-prod')

      expect(needs('deploy-prod')).to include('resolve', 'gate')
      expect(prod['if'].to_s).not_to match(/always\(\)|failure\(\)|cancelled\(\)/)
      %w[announce-stage announce-prod].each do |name|
        expect(needs_closure(name)).to include('gate'), "#{name} can run without the gate passing"
      end
      expect(needs_closure('deploy-prod')).not_to include('restore-dev')
    end

    it 'is eligible, behind the prod environment, once the gate passed',
       requirement: 'a-failed-gate-stops-promotion-to-prod',
       scenario: 'gate-success-allows-prod-approval' do
      prod = job('deploy-prod')

      expect(prod['environment']).to eq('prod')
      expect(prod).not_to have_key('if')
      expect(needs('deploy-prod')).to include('gate')
      expect(YAML.dump(prod)).to include('needs.resolve.outputs.tag')
      expect(YAML.dump(prod)).not_to include('client_payload')
    end
  end

  describe 'restoring dev' do
    it 'redeploys the ledger version with a verified artifact and smoke checks',
       requirement: 'a-failed-gate-restores-dev-to-the-last-recorded-release',
       scenario: 'dev-is-restored-after-a-gate-failure' do
      restore = job('restore-dev')
      ledger = index_of_step('restore-dev') { |s| s['run'].to_s.include?('bin/last-good-release') }
      credentials = index_of_step('restore-dev') do |s|
        s['uses'].to_s.start_with?('aws-actions/configure-aws-credentials')
      end
      deploy = index_of_step('restore-dev') { |s| s['run'].to_s.include?('sam deploy') }
      smoke = index_of_step('restore-dev') { |s| s['run'].to_s.include?('bin/smoke') }

      expect(needs('restore-dev')).to contain_exactly('resolve', 'deploy-dev', 'gate')
      expect(restore['environment']).to eq('dev')
      expect(restore['permissions']).to eq({ 'id-token' => 'write', 'contents' => 'read' })
      expect(runs('restore-dev').join("\n")).to include('gh release download')
      expect(runs('restore-dev').join("\n")).to include('vars.DEV_STACK_NAME')
      expect(ledger).to be < credentials # every refusal happens before AWS can be touched
      expect(credentials).to be < deploy
      expect(deploy).to be < smoke
    end

    it 'ends failed after a successful restore',
       requirement: 'a-failed-gate-restores-dev-to-the-last-recorded-release',
       scenario: 'restored-run-is-still-marked-failed' do
      last = steps('restore-dev').last

      expect(last['run']).to match(/\bexit 1\b/)
      expect(last).not_to have_key('continue-on-error')
      expect(steps('restore-dev').none? { |s| s.key?('continue-on-error') }).to be(true)
      expect(job('restore-dev')).not_to have_key('continue-on-error')
    end

    it 'runs only when dev deployed and the gate failed',
       requirement: 'a-failed-gate-restores-dev-to-the-last-recorded-release',
       scenario: 'restore-does-not-run-for-other-outcomes' do
      expect(condition(job('restore-dev')['if'])).to eq(RESTORE_IF)
    end

    it 'verifies the artifact checksum before anything is deployed',
       requirement: 'a-failed-gate-restores-dev-to-the-last-recorded-release',
       scenario: 'corrupt-artifact-is-not-deployed' do
      verify = index_of_step('restore-dev') { |s| s['run'].to_s.include?('shasum -a 256 -c') }
      deploy = index_of_step('restore-dev') { |s| s['run'].to_s.include?('sam deploy') }

      expect(verify).to be < deploy
      expect(steps('restore-dev')[verify]['run']).not_to match(/\|\|\s*(true|:)/)
      expect(steps('restore-dev')[verify]).not_to have_key('continue-on-error')
    end
  end

  describe 'announcements' do
    def dispatch_step(name)
      steps(name).find { |s| s['run'].to_s.include?('repos/greeterhq/greeter-acceptance/dispatches') } ||
        raise("#{name} has no dispatch step")
    end

    def step_env_values(step)
      step.fetch('env').values.map(&:to_s)
    end

    it 'announces stage after the gate passes',
       requirement: 'deployed-releases-are-announced-to-the-acceptance-ledgers',
       scenario: 'stage-is-announced-after-the-gate-passes' do
      step = dispatch_step('announce-stage')

      expect(needs('announce-stage')).to include('resolve', 'gate')
      expect(job('announce-stage')).not_to have_key('if')
      expect(step['run']).to include('event_type=channel-released')
      expect(step['run']).to include('client_payload[channel]=http')
      expect(step_env_values(step)).to include('${{ needs.resolve.outputs.tag }}',
                                               '${{ needs.resolve.outputs.sha }}', 'stage')
    end

    it 'announces prod after the prod deployment and its smoke pass',
       requirement: 'deployed-releases-are-announced-to-the-acceptance-ledgers',
       scenario: 'prod-is-announced-after-the-prod-smoke-passes' do
      step = dispatch_step('announce-prod')

      expect(needs('announce-prod')).to include('resolve', 'deploy-prod')
      expect(job('announce-prod')).not_to have_key('if')
      expect(step['run']).to include('client_payload[channel]=http')
      expect(step_env_values(step)).to include('${{ needs.resolve.outputs.tag }}',
                                               '${{ needs.resolve.outputs.sha }}', 'prod')
      expect(runs('deploy-prod').join("\n")).to include('bin/smoke') # the smoke is inside deploy-prod
    end

    it 'sends nothing unless the job it depends on succeeded',
       requirement: 'deployed-releases-are-announced-to-the-acceptance-ledgers',
       scenario: 'nothing-is-announced-for-a-failed-stage-or-prod' do
      %w[announce-stage announce-prod].each do |name|
        expect(job(name)['if'].to_s).not_to match(/always\(\)|failure\(\)|cancelled\(\)/)
        expect(job(name)).not_to have_key('continue-on-error')
      end
      expect(needs('announce-stage')).to include('gate')
      expect(needs('announce-prod')).to include('deploy-prod')
      expect(job('gate')).not_to have_key('continue-on-error')
      expect(job('deploy-prod')).not_to have_key('continue-on-error')
    end
  end

  describe 'announce token' do
    def mint_step(name)
      steps(name).find { |s| s['uses'].to_s.start_with?('actions/create-github-app-token@') } ||
        raise("#{name} mints no App token")
    end

    def dispatch_index(name)
      index_of_step(name) { |s| s['run'].to_s.include?('repos/greeterhq/greeter-acceptance/dispatches') }
    end

    it 'declares empty permissions on both announce jobs',
       requirement: 'announcements-hold-only-a-single-repository-app-token',
       scenario: 'no-workflow-token-permissions' do
      %w[announce-stage announce-prod].each do |name|
        expect(job(name)).to have_key('permissions')
        expect(job(name)['permissions']).to eq({})
      end
    end

    it 'mints for owner greeterhq and the acceptance repository only, just before use',
       requirement: 'announcements-hold-only-a-single-repository-app-token',
       scenario: 'token-is-scoped-to-one-repository' do
      %w[announce-stage announce-prod].each do |name|
        mint = mint_step(name)

        expect(mint['uses']).to eq('actions/create-github-app-token@v3')
        expect(mint['with']).to include(
          'client-id' => '${{ vars.DISPATCH_APP_CLIENT_ID }}',
          'private-key' => '${{ secrets.DISPATCH_APP_PRIVATE_KEY }}',
          'owner' => 'greeterhq',
          'repositories' => 'greeter-acceptance'
        )
        expect(mint['id']).not_to be_nil
        expect(index_of_step(name) { |s| s.equal?(mint) } + 1).to eq(dispatch_index(name))
      end
    end

    it 'requests only the contents write permission',
       requirement: 'announcements-hold-only-a-single-repository-app-token',
       scenario: 'token-permissions-are-narrowed' do
      %w[announce-stage announce-prod].each do |name|
        scoped = mint_step(name)['with'].select { |key, _| key.start_with?('permission-') }

        expect(scoped).to eq({ 'permission-contents' => 'write' })
      end
    end

    it 'passes event values only through env and the token only as GH_TOKEN',
       requirement: 'announcements-hold-only-a-single-repository-app-token',
       scenario: 'event-values-are-not-interpolated-into-scripts' do
      %w[announce-stage announce-prod].each do |name|
        step = steps(name).find { |s| s['run'].to_s.include?('/dispatches') }
        mint = mint_step(name)

        expect(step['run']).not_to include('${{')
        expect(step['run']).not_to match(/\s-F\s|--field\b/)
        expect(step['run']).to match(/\s-f\s/)
        expect(step['env']['GH_TOKEN']).to eq("${{ steps.#{mint['id']}.outputs.token }}")
      end
    end
  end

  # S12: untrusted event data must reach scripts only through env.
  it 'never interpolates event or needs expressions into run bodies of the new jobs' do
    NEW_JOBS.reject { |name| name == 'gate' }.each do |name|
      runs(name).each do |body|
        expect(body).not_to match(/\$\{\{\s*(github\.event|needs)\./),
                            "#{name} interpolates an expression into a run body"
      end
    end
  end

  describe 'lint' do
    it 'runs the acceptance ref check in the lint job',
       requirement: 'the-acceptance-suite-pin-is-consistent',
       scenario: 'lint-runs-the-check' do
      lint_steps = ci.fetch('jobs').fetch('lint').fetch('steps')
      commands = lint_steps.filter_map { |s| s['run'] }

      expect(commands.map(&:strip)).to include('bin/check-acceptance-ref')
      rubocop_at = lint_steps.index { |s| s['run'].to_s.include?('rubocop') }
      check_at = lint_steps.index { |s| s['run'].to_s.strip == 'bin/check-acceptance-ref' }
      expect(check_at).to be > rubocop_at
    end
  end
end
