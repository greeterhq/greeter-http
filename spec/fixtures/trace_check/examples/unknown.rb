# frozen_string_literal: true

# Tag list read as text by spec/trace_check_spec.rb. Never run.
RSpec.describe 'trace check fixture: unknown requirement' do
  it 'names a requirement that has no heading', requirement: 'no-such-requirement', scenario: 'covered-scenario' do
    expect(true).to be(true)
  end
end
