# frozen_string_literal: true

# Tag list read as text by spec/trace_check_spec.rb. Never run.
RSpec.describe 'trace check fixture: change deltas' do
  it 'uses a scenario added by a MODIFIED delta',
     requirement: 'covered-requirement',
     scenario: 'modified-extra-scenario' do
    expect(true).to be(true)
  end

  it 'uses a requirement known only from an archived change',
     requirement: 'archived-only',
     scenario: 'archived-scenario' do
    expect(true).to be(true)
  end

  it 'uses a requirement from a REMOVED section',
     requirement: 'removed-requirement',
     scenario: 'removed-scenario' do
    expect(true).to be(true)
  end

  it 'uses the new name from a RENAMED section', requirement: 'new-name', scenario: 'new-name' do
    expect(true).to be(true)
  end
end
