# frozen_string_literal: true

# Run in a subprocess by spec/tooling/repo_trace_formatter_spec.rb.
# The requirement value is not a slug, so the formatter must refuse it.
RSpec.describe 'Malformed tag' do
  it 'carries a guest name as its requirement', requirement: 'Alice Smith', scenario: 'ok-scenario' do
    expect(1).to eq(1)
  end
end
