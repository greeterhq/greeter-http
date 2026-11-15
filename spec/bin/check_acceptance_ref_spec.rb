# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'

# Red tests for adopt-acceptance-gate (capability: acceptance-gated-release),
# requirement "The acceptance suite pin is consistent".
#
# bin/check-acceptance-ref keeps the gate job's `uses:` ref and its
# `acceptance_ref` input equal and vX.Y.Z, and requires the gate to come from
# greeterhq/greeter-acceptance. The script is loaded only when it exists, so
# before the implementation these examples fail with NameError on
# CheckAcceptanceRef.
#
# Interface under test (defined by these specs):
#   CheckAcceptanceRef.run(argv, stdout:, stderr:) -> Integer exit status
#     argv  [workflow_path]; defaults to .github/workflows/cd.yml
#     returns 0 on success; on failure prints reasons on stderr and returns 1
script = File.expand_path('../../bin/check-acceptance-ref', __dir__)
load script if File.exist?(script)

RSpec.describe 'bin/check-acceptance-ref' do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def fixture_path(name)
    File.expand_path("../fixtures/workflows/#{name}.yml", __dir__)
  end

  def check(path)
    CheckAcceptanceRef.run([path], stdout: stdout, stderr: stderr)
  end

  # Writes a one-job workflow with the given refs and returns its path.
  def workflow_with(uses_ref:, acceptance_ref:)
    dir = Dir.mktmpdir('check-acceptance-ref')
    path = File.join(dir, 'cd.yml')
    File.write(path, <<~YAML)
      name: CD
      "on":
        repository_dispatch:
          types: [deploy-release]
      jobs:
        gate:
          uses: greeterhq/greeter-acceptance/.github/workflows/gate.yml@#{uses_ref}
          with:
            acceptance_ref: #{acceptance_ref}
            channel: http
    YAML
    path
  end

  describe 'the acceptance suite pin is consistent' do
    it 'passes when the refs match and are versions',
       requirement: 'the-acceptance-suite-pin-is-consistent',
       scenario: 'matching-refs-pass' do
      expect(check(fixture_path('gate_match'))).to eq(0)
      expect(stderr.string).to eq('')
    end

    it 'fails naming both values when the refs differ',
       requirement: 'the-acceptance-suite-pin-is-consistent',
       scenario: 'differing-refs-fail' do
      expect(check(fixture_path('gate_mismatch'))).to eq(1)
      expect(stderr.string).to include('v0.2.2').and include('v0.2.1')
    end

    it 'fails naming the value when a ref is not vX.Y.Z',
       requirement: 'the-acceptance-suite-pin-is-consistent',
       scenario: 'refs-that-are-not-versions-fail' do
      expect(check(fixture_path('gate_not_version'))).to eq(1)
      expect(stderr.string).to include('v0.2')

      stderr.truncate(0)
      stderr.rewind
      expect(check(workflow_with(uses_ref: 'main', acceptance_ref: 'main'))).to eq(1)
      expect(stderr.string).to include('main')
    end

    it 'fails naming the source when the gate is not the acceptance repository workflow',
       requirement: 'the-acceptance-suite-pin-is-consistent',
       scenario: 'gate-must-come-from-the-acceptance-repository' do
      expect(check(fixture_path('gate_wrong_source'))).to eq(1)
      expect(stderr.string).to include('someoneelse/greeter-acceptance')
    end
  end

  # Not OpenSpec scenarios: behaviour recorded in design.md decision 6.
  it 'fails when there is no gate job' do
    expect(check(fixture_path('gate_missing'))).to eq(1)
    expect(stderr.string).to match(/gate/i)
  end

  it 'passes for the repository cd.yml' do
    status = CheckAcceptanceRef.run([], stdout: stdout, stderr: stderr)

    expect(status).to eq(0), stderr.string
  end
end
