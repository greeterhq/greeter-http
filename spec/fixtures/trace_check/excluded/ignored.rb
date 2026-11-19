# frozen_string_literal: true

# Matched by the example glob but also by the exclude glob, so the trace check
# must never read these tags.
RSpec.describe 'trace check fixture: excluded' do
  it 'names an unknown requirement', requirement: 'excluded-unknown-requirement', scenario: 'excluded-scenario' do
    expect(true).to be(true)
  end
end
