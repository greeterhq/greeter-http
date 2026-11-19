# frozen_string_literal: true

# Run in a subprocess by spec/tooling/repo_trace_formatter_spec.rb with
# RepoTraceFormatter. Descriptions contain a guest name on purpose: it must
# never reach the trace file.
RSpec.describe 'Statuses for Alice Smith' do
  it 'passes for Alice Smith', requirement: 'fixture-requirement', scenario: 'passing-scenario' do
    expect(1).to eq(1)
  end

  it 'fails for Alice Smith', requirement: 'fixture-requirement', scenario: 'failing-scenario' do
    expect(1).to eq(2)
  end

  it 'is skipped for Alice Smith', requirement: 'fixture-requirement', scenario: 'skipped-scenario',
                                   skip: 'not now' do
    expect(1).to eq(1)
  end

  it 'is pending for Alice Smith', requirement: 'fixture-requirement', scenario: 'pending-scenario' do
    pending 'not implemented'
    expect(1).to eq(2)
  end

  it 'is untagged for Alice Smith' do
    expect(1).to eq(1)
  end

  it 'has only a requirement for Alice Smith', requirement: 'fixture-requirement' do
    expect(1).to eq(1)
  end
end
