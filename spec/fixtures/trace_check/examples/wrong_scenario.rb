# frozen_string_literal: true

# Tag list read as text by spec/trace_check_spec.rb. Never run.
RSpec.describe 'trace check fixture: scenario under the wrong requirement' do
  it 'uses a scenario that belongs to another requirement',
     requirement: 'covered-requirement',
     scenario: 'only-under-other' do
    expect(true).to be(true)
  end
end
