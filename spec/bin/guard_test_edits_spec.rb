# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# Specs for bin/guard-test-edits, the PreToolUse guard that keeps the agent away
# from spec/, features/, the hook config and the guard itself (see
# .kiro/hooks/tdd-guards.json).
#
# Every example runs a COPY of the script in a throwaway directory, so the real
# tmp/allow-test-edits flag is never read or written. To run the table against
# another version of the script (for example to see it fail against the previous
# guard), set GUARD_SCRIPT to a path relative to the repository root:
#
#   git show <commit>^:bin/guard-test-edits > tmp/old-guard
#   GUARD_SCRIPT=tmp/old-guard bundle exec rspec spec/bin/guard_test_edits_spec.rb
#
# These specs prove the script's decisions. They cannot prove that Kiro calls the
# hook; tmp/guard.log (written by the script) is the runtime evidence for that.
RSpec.describe 'bin/guard-test-edits' do
  GUARD_REPO_ROOT = File.expand_path('../..', __dir__)
  GUARD_SCRIPT = File.expand_path(ENV.fetch('GUARD_SCRIPT', 'bin/guard-test-edits'), GUARD_REPO_ROOT)
  GUARD_FLAG = 'allow-test-edits'

  # The trigger names Kiro accepts for hooks. A name outside this list is skipped
  # with "Hook trigger is not a recognized name" and the hook never runs.
  GUARD_VALID_TRIGGERS = %w[
    PreToolUse PostToolUse SessionStart Stop UserPromptSubmit
    PreTaskExec PostTaskExec PostFileCreate PostFileSave PostFileDelete
  ].freeze

  def self.guard_input(path)
    { 'path' => path, 'text' => 'x' }
  end

  def self.shell(command)
    { 'command' => command }
  end

  # label, tool, tool_input, flag present?, expected decision
  GUARD_CASES = [
    ['fs_write to spec/', 'fs_write', guard_input('/r/spec/a_spec.rb'), false, :block],
    ['str_replace in features/', 'str_replace',
     { 'path' => '/r/features/step_definitions/x.rb', 'oldStr' => 'a', 'newStr' => 'b' }, false, :block],
    ['fs_append to a relative spec/ path', 'fs_append', guard_input('spec/fixtures/a.json'), false, :block],
    ['delete_file in spec/', 'delete_file', { 'targetFile' => '/r/spec/a_spec.rb' }, false, :block],
    ['smart_relocate out of spec/', 'smart_relocate',
     { 'sourcePath' => 'spec/a.rb', 'destinationPath' => 'lib/b.rb' }, false, :block],
    ['semantic_rename in features/', 'semantic_rename',
     { 'path' => 'features/support/env.rb', 'line' => 1, 'character' => 1 }, false, :block],
    ['fs_write to lib/', 'fs_write', guard_input('/r/lib/x.rb'), false, :allow],
    ['fs_write under openspec/specs/', 'fs_write', guard_input('/r/openspec/specs/x/spec.md'), false, :allow],
    ['fs_write to docs/spec.md', 'fs_write', guard_input('/r/docs/spec.md'), false, :allow],
    ['fs_write to the hook config', 'fs_write', guard_input('/r/.kiro/hooks/tdd-guards.json'), false, :block],
    ['fs_write to the guard itself', 'fs_write', guard_input('/r/bin/guard-test-edits'), false, :block],
    ['fs_write to the flag, flag absent', 'fs_write', guard_input("/r/tmp/#{GUARD_FLAG}"), false, :block],
    ['fs_write to the flag, flag present', 'fs_write', guard_input("/r/tmp/#{GUARD_FLAG}"), true, :block],
    ['fs_write to spec/ with the flag present', 'fs_write', guard_input('/r/spec/a_spec.rb'), true, :allow],
    ['fs_write whose content looks like a path key', 'fs_write',
     { 'path' => '/r/lib/y.rb', 'text' => '{"path": "spec/x.rb"}' }, false, :allow],
    ['a read-only tool', 'read_file', { 'path' => '/r/spec/a_spec.rb' }, false, :allow],
    ['an unknown tool', 'something_else', { 'x' => 1 }, false, :allow],
    ['shell sed -i on a spec', 'execute_bash', shell("sed -i '' 's/a/b/' spec/a_spec.rb"), false, :block],
    ['shell redirect into spec/', 'execute_bash', shell('echo hi > spec/zz.txt'), false, :block],
    ['shell redirect without a space', 'execute_bash', shell('echo hi >spec/zz.txt'), false, :block],
    ['shell append to an absolute features/ path', 'execute_bash', shell('echo hi >> /r/features/zz.txt'),
     false, :block],
    ['shell touch of the flag', 'execute_bash', shell("touch tmp/#{GUARD_FLAG}"), false, :block],
    ['shell ls of the flag', 'execute_bash', shell("ls tmp/#{GUARD_FLAG}"), false, :block],
    ['shell git checkout of a spec file', 'execute_bash', shell('git checkout spec/app_spec.rb'), false, :block],
    ['shell cp into features/', 'execute_bash', shell('cp tmp/x.rb features/y.rb'), false, :block],
    ['shell File.write into spec/', 'execute_bash', shell(%q(ruby -e 'File.write("spec/x.rb", "y")')),
     false, :block],
    ['shell rubocop -A on spec/', 'execute_bash', shell('bundle exec rubocop -A spec/bin'), false, :block],
    ['shell edit of the guard', 'execute_bash', shell("sed -i '' 's/a/b/' bin/guard-test-edits"), false, :block],
    ['shell write to the hook config', 'execute_bash', shell('echo {} > .kiro/hooks/tdd-guards.json'),
     false, :block],
    ['shell write to spec/ with the flag present', 'execute_bash', shell('echo hi > spec/zz.txt'), true, :allow],
    ['shell rspec redirecting output to tmp/', 'execute_bash',
     shell('bundle exec rspec spec/bin > tmp/out.txt 2>&1'), false, :allow],
    ['shell grep over spec and features', 'execute_bash', shell('grep -rn count spec features | head'),
     false, :allow],
    ['shell rm in tmp then ls spec', 'execute_bash', shell('rm -f tmp/foo && ls spec'), false, :allow],
    ['shell tee to tmp from a spec', 'execute_bash', shell('cat spec/a_spec.rb | tee tmp/copy.rb'), false, :allow],
    ['shell sed -n on a spec', 'execute_bash', shell('sed -n 1,5p spec/a_spec.rb'), false, :allow],
    ['shell cucumber redirecting output to tmp/', 'execute_bash',
     shell('bundle exec cucumber features/a.feature > tmp/c.txt'), false, :allow],
    ['shell mv inside openspec/', 'execute_bash', shell('mv openspec/changes/a openspec/changes/archive/b'),
     false, :allow],
    ['shell git status and diff on spec/', 'execute_bash', shell('git status --short spec; git diff spec/a.rb'),
     false, :allow]
  ].freeze

  let(:sandbox) { Dir.mktmpdir('guard-spec') }

  before do
    FileUtils.mkdir_p([File.join(sandbox, 'bin'), File.join(sandbox, 'tmp')])
    copy = File.join(sandbox, 'bin', 'guard-test-edits')
    FileUtils.cp(GUARD_SCRIPT, copy)
    File.chmod(0o755, copy)
  end

  after { FileUtils.remove_entry(sandbox) }

  # Runs the sandboxed guard with a payload shaped like Kiro's PreToolUse input.
  # Returns [exit status, stderr].
  def run_guard(tool, input, flag: false)
    flag_path = File.join(sandbox, 'tmp', GUARD_FLAG)
    flag ? FileUtils.touch(flag_path) : FileUtils.rm_f(flag_path)
    payload = JSON.generate('hook_event_name' => 'PreToolUse', 'cwd' => sandbox,
                            'tool_name' => tool, 'tool_input' => input)
    _out, err, status = Open3.capture3(File.join(sandbox, 'bin', 'guard-test-edits'),
                                       stdin_data: payload, chdir: sandbox)
    [status.exitstatus, err]
  end

  describe 'decisions' do
    GUARD_CASES.each do |label, tool, input, flag, expected|
      it "#{expected == :block ? 'blocks' : 'allows'}: #{label}" do
        status, err = run_guard(tool, input, flag: flag)

        if expected == :block
          expect(status).to eq(2)
          expect(err).to start_with('Blocked:')
        else
          expect(status).to eq(0)
          expect(err).to be_empty
        end
      end
    end
  end

  describe 'audit log' do
    it 'records one tab-separated line per matched call and nothing for other tools' do
      run_guard('fs_write', guard_log_input('/r/spec/a_spec.rb'))
      run_guard('fs_write', guard_log_input('/r/lib/a.rb'))
      run_guard('something_else', { 'x' => 1 })

      rows = File.readlines(File.join(sandbox, 'tmp', 'guard.log'), chomp: true).map { |line| line.split("\t") }

      expect(rows.map { |row| row[1..2] }).to eq([%w[fs_write block], %w[fs_write allow]])
      expect(rows.first[0]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)
      expect(rows.first[3]).to eq('protected path, no flag')
      expect(rows.first[4]).to eq('/r/spec/a_spec.rb')
    end

    def guard_log_input(path)
      { 'path' => path, 'text' => 'x' }
    end
  end

  describe 'hook configuration' do
    let(:hooks) do
      JSON.parse(File.read(File.join(GUARD_REPO_ROOT, '.kiro', 'hooks', 'tdd-guards.json'))).fetch('hooks')
    end
    let(:guard_hook) { hooks.find { |hook| hook['name'] == 'protect-tests-during-apply' } }
    let(:matcher) { Regexp.new("\\A(?:#{guard_hook.fetch('matcher')})\\z") }

    it 'runs the guard script on PreToolUse' do
      expect(guard_hook).not_to be_nil
      expect(guard_hook['trigger']).to eq('PreToolUse')
      expect(guard_hook.dig('action', 'command')).to eq('bin/guard-test-edits')
    end

    it 'matches every tool the script can block' do
      blockable = GUARD_CASES.select { |c| c[4] == :block }.map { |c| c[1] }.uniq

      expect(blockable.grep_v(matcher)).to be_empty
    end

    it 'does not intercept read-only tools' do
      read_only = %w[read_file read_code grep_search file_search list_directory]

      expect(read_only.grep(matcher)).to be_empty
    end

    it 'only uses trigger names Kiro recognises' do
      expect(hooks.map { |hook| hook['trigger'] } - GUARD_VALID_TRIGGERS).to be_empty
    end

    it 'keeps the real script executable' do
      expect(File.executable?(File.join(GUARD_REPO_ROOT, 'bin', 'guard-test-edits'))).to be(true)
    end
  end
end
