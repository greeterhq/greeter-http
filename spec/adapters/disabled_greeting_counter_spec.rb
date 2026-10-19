# frozen_string_literal: true

require 'spec_helper'

# The null-object counter used when GREETER_COUNTER_ENABLED=false: greet, but
# don't count (item 5). Also covers App selecting it via the env flag.
RSpec.describe 'GreeterHttp::Adapters::DisabledGreetingCounter' do
  subject(:counter) { GreeterHttp::Adapters::DisabledGreetingCounter.new }

  def increment(synthetic: false)
    counter.increment(
      guest: 'Alice Bonsu',
      idempotency_key: SecureRandom.uuid,
      fingerprint: 'fp',
      synthetic: synthetic
    )
  end

  it 'returns a nil (not-tracked) count' do
    expect(increment.count).to be_nil
  end

  it 'reports every call as a fresh, non-replayed greeting' do
    expect(increment.replayed?).to be(false)
  end

  it 'still validates its arguments (nil fingerprint is a programming error)' do
    expect do
      counter.increment(guest: 'Alice', idempotency_key: 'k', fingerprint: nil)
    end.to raise_error(ArgumentError)
  end

  it 'accepts the synthetic flag without changing behaviour' do
    expect(increment(synthetic: true).count).to be_nil
  end

  describe 'App selection via GREETER_COUNTER_ENABLED' do
    around do |example|
      saved = ENV.fetch('GREETER_COUNTER_ENABLED', nil)
      example.run
    ensure
      saved.nil? ? ENV.delete('GREETER_COUNTER_ENABLED') : (ENV['GREETER_COUNTER_ENABLED'] = saved)
    end

    it 'selects the disabled counter when the flag is false' do
      ENV['GREETER_COUNTER_ENABLED'] = 'false'
      counter = GreeterHttp::App.counter_from_env(default: 'memory')
      expect(counter).to be_a(GreeterHttp::Adapters::DisabledGreetingCounter)
    end

    it 'selects the real backend when the flag is unset' do
      ENV.delete('GREETER_COUNTER_ENABLED')
      counter = GreeterHttp::App.counter_from_env(default: 'memory')
      expect(counter).to be_a(GreeterHttp::Adapters::InMemoryGreetingCounter)
    end

    it 'treats off/0/no as disabled too' do
      %w[off 0 NO].each do |val|
        ENV['GREETER_COUNTER_ENABLED'] = val
        expect(GreeterHttp::App.counter_from_env(default: 'memory'))
          .to be_a(GreeterHttp::Adapters::DisabledGreetingCounter)
      end
    end
  end
end
