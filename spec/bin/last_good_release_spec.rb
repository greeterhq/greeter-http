# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'stringio'

# Red tests for adopt-acceptance-gate (capability: acceptance-gated-release),
# requirement "Restore refuses an unsafe or unknown target".
#
# bin/last-good-release reads the stage ledger and prints the http version that
# restore-dev should redeploy. The script is loaded only when it exists, so
# before the implementation these examples fail with NameError on
# LastGoodRelease. The ledger is never fetched over the network here: the
# fetcher is injected.
#
# Interface under test (defined by these specs):
#   LastGoodRelease::LEDGER_URL                         fixed https URL
#   LastGoodRelease.run(argv, fetcher:, stdout:, stderr:) -> Integer exit status
#     argv    [failed_tag]
#     fetcher #call(url) -> String body; raises on any fetch failure
#     prints only the version (plus newline) on stdout on success;
#     prints one line "last-good-release: <reason>" on stderr and returns 1 on
#     any failure, with nothing on stdout.
script = File.expand_path('../../bin/last-good-release', __dir__)
load script if File.exist?(script)

RSpec.describe 'bin/last-good-release' do
  let(:ledger_url) { 'https://raw.githubusercontent.com/greeterhq/greeter-acceptance/ledger-stage/deployed.json' }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def fixture(name)
    File.read(File.join(File.expand_path('../fixtures/ledger', __dir__), "#{name}.json"))
  end

  def run_with(body, failed_tag: 'v0.5.21')
    fetcher = ->(_url) { body }
    LastGoodRelease.run([failed_tag], fetcher: fetcher, stdout: stdout, stderr: stderr)
  end

  def reset_streams
    [stdout, stderr].each do |io|
      io.truncate(0)
      io.rewind
    end
  end

  def expect_failure(status, reason)
    expect(status).to eq(1)
    expect(stdout.string).to eq('')
    expect(stderr.string).to match(reason)
    expect(stderr.string).to start_with('last-good-release:')
    expect(stderr.string.lines.size).to eq(1)
  end

  describe 'restore refuses an unsafe or unknown target' do
    it 'prints the recorded version for a valid ledger and reads only the fixed URL',
       requirement: 'restore-refuses-an-unsafe-or-unknown-target',
       scenario: 'valid-ledger-prints-the-recorded-version' do
      urls = []
      fetcher = lambda do |url|
        urls << url
        fixture('valid')
      end

      status = LastGoodRelease.run(['v0.5.21'], fetcher: fetcher, stdout: stdout, stderr: stderr)

      expect(status).to eq(0)
      expect(stdout.string).to eq("v0.5.20\n")
      expect(stderr.string).to eq('')
      expect(urls).to eq([ledger_url])
      expect(LastGoodRelease::LEDGER_URL).to eq(ledger_url)
    end

    it 'fails naming the ledger as unreadable when it cannot be fetched or is not JSON',
       requirement: 'restore-refuses-an-unsafe-or-unknown-target',
       scenario: 'unreadable-ledger-fails' do
      raising = ->(_url) { raise IOError, 'connection reset' }
      status = LastGoodRelease.run(['v0.5.21'], fetcher: raising, stdout: stdout, stderr: stderr)
      expect_failure(status, /unreadable/i)

      reset_streams
      expect_failure(run_with(fixture('not_json')), /unreadable/i)
    end

    it 'fails naming the schema when it is not greeterhq.deployed.v1',
       requirement: 'restore-refuses-an-unsafe-or-unknown-target',
       scenario: 'wrong-schema-fails' do
      expect_failure(run_with(fixture('wrong_schema')), /schema/i)
    end

    it 'fails saying there is no recorded http version when the http entry is missing',
       requirement: 'restore-refuses-an-unsafe-or-unknown-target',
       scenario: 'missing-http-entry-fails' do
      expect_failure(run_with(fixture('no_http')), /no recorded http version/i)
    end

    it 'fails saying the version is invalid when it is not vX.Y.Z',
       requirement: 'restore-refuses-an-unsafe-or-unknown-target',
       scenario: 'bad-recorded-version-fails' do
      expect_failure(run_with(fixture('bad_version')), /invalid/i)

      reset_streams
      injected = JSON.parse(fixture('valid'))
      injected['channels']['http']['version'] = 'v0.5.20; x'
      expect_failure(run_with(JSON.generate(injected)), /invalid/i)
    end

    it 'fails saying it would redeploy the failed version when the ledger records it',
       requirement: 'restore-refuses-an-unsafe-or-unknown-target',
       scenario: 'recorded-version-equal-to-the-failed-version-fails' do
      expect_failure(run_with(fixture('valid'), failed_tag: 'v0.5.20'), /redeploy the failed version/i)
    end

    it 'neutralises untrusted ledger text in its message',
       requirement: 'restore-refuses-an-unsafe-or-unknown-target',
       scenario: 'untrusted-ledger-text-is-neutralised-in-messages' do
      status = run_with(fixture('hostile_version'))

      expect(status).to eq(1)
      expect(stdout.string).to eq('')
      message = stderr.string
      expect(message).to start_with('last-good-release:')
      expect(message.lines.size).to eq(1)
      expect(message.lines.none? { |line| line.start_with?('::') }).to be(true)
      expect(message).to include('\\n') # the line break is shown escaped, not emitted
      expect(message.length).to be < 200 # the value is cut, not echoed whole
    end
  end

  # Not an OpenSpec scenario: the extra ledger check recorded in design.md
  # decision 5 (the ledger must be the stage ledger).
  it 'refuses a ledger for another environment' do
    expect_failure(run_with(fixture('wrong_environment')), /environment/i)
  end
end
