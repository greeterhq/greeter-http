# frozen_string_literal: true

# Run in a subprocess by spec/tooling/repo_trace_formatter_spec.rb.
# The shared example reports the same location for both inclusions, so the two
# results collapse to one with the worst status (failed).
RSpec.shared_examples 'a checked value' do |value|
  it 'is one' do
    expect(value).to eq(1)
  end
end

RSpec.describe 'Shared examples' do
  context 'with the value one', requirement: 'fixture-requirement', scenario: 'shared-scenario' do
    it_behaves_like 'a checked value', 1
  end

  context 'with the value two', requirement: 'fixture-requirement', scenario: 'shared-scenario' do
    it_behaves_like 'a checked value', 2
  end
end
