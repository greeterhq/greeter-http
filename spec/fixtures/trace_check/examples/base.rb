# frozen_string_literal: true

# Tag list read as text by spec/trace_check_spec.rb. Never run.
RSpec.describe 'trace check fixture: base' do
  it 'covers the covered requirement', requirement: 'covered-requirement', scenario: 'covered-scenario' do
    expect(true).to be(true)
  end

  it 'covers a same-text scenario',
     requirement: 'same-text-scenario',
     scenario: 'same-text-scenario' do
    expect(true).to be(true)
  end

  it 'covers the other requirement', requirement: 'other-requirement', scenario: 'only-under-other' do
    expect(true).to be(true)
  end

  it 'covers the added in-flight requirement', requirement: 'added-in-flight', scenario: 'added-scenario' do
    expect(true).to be(true)
  end

  it 'is untagged' do
    expect(true).to be(true)
  end
end
