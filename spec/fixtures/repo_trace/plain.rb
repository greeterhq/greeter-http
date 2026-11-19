# frozen_string_literal: true

# Run in a subprocess by spec/tooling/repo_trace_formatter_spec.rb to test
# values taken from the environment (GITHUB_SHA, GITHUB_RUN_ID).
RSpec.describe 'Plain' do
  it 'passes', requirement: 'fixture-requirement', scenario: 'passing-scenario' do
    expect(1).to eq(1)
  end
end
