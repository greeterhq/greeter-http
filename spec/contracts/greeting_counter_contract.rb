# frozen_string_literal: true

# Behavioral contract shared by every GreetingCounter implementation
# (in-memory, DynamoDB, ...). Include it with a `subject` that is a fresh,
# empty counter:
#
#   it_behaves_like 'a greeting counter' do
#     let(:counter) { InMemoryGreetingCounter.new }
#   end
#
# Each implementation must satisfy the same observable behavior.
RSpec.shared_examples 'a greeting counter' do
  # Each example gets a distinct guest so parallel runs don't collide, and a
  # fresh idempotency key per call so these count-focused examples exercise
  # real increments rather than replays. The fingerprint defaults to a
  # per-guest value; pass it explicitly (including nil) to override.
  def increment(guest, key: SecureRandom.uuid, fingerprint: "fp-#{guest}", synthetic: false)
    counter.increment(
      guest: guest,
      idempotency_key: key,
      fingerprint: fingerprint,
      synthetic: synthetic
    )
  end

  def count_of(result)
    result.respond_to?(:count) ? result.count : result.fetch(:count)
  end

  let(:guest) { "Guest #{SecureRandom.hex(4)}" }

  it 'returns 1 on the first increment for a guest' do
    expect(count_of(increment(guest))).to eq(1)
  end

  it 'increases monotonically by one across successive increments' do
    counts = Array.new(5) { count_of(increment(guest)) }
    expect(counts).to eq([1, 2, 3, 4, 5])
  end

  it 'counts each guest independently' do
    alice = "Alice #{SecureRandom.hex(4)}"
    bob   = "Bob #{SecureRandom.hex(4)}"

    3.times { increment(alice) }
    1.times { increment(bob) }

    expect(count_of(increment(alice))).to eq(4)
    expect(count_of(increment(bob))).to eq(2)
  end

  it 'isolates synthetic traffic from the same guest\'s real count' do
    # Real and synthetic increments for the SAME guest name must not share a
    # counter: synthetic monitoring traffic never inflates the real count.
    2.times { increment(guest, synthetic: false) }
    2.times { increment(guest, synthetic: true) }

    # The next real increment is 3 (not 5), and the next synthetic is 3 too —
    # two independent sequences under the one guest name.
    expect(count_of(increment(guest, synthetic: false))).to eq(3)
    expect(count_of(increment(guest, synthetic: true))).to eq(3)
  end

  it 'totals exactly 10 when 10 threads increment the same guest concurrently' do
    results = []
    mutex = Mutex.new

    threads = Array.new(10) do
      Thread.new do
        r = increment(guest)
        mutex.synchronize { results << count_of(r) }
      end
    end
    threads.each(&:join)

    # No lost updates: the 10 returned counts are exactly 1..10, and the final
    # observed value is 10.
    expect(results.sort).to eq((1..10).to_a)
  end

  # Idempotency is part of the GreetingCounter port contract, so every
  # implementation (in-memory, DynamoDB, ...) must satisfy it. These examples
  # pin the key and fingerprint to exercise replay vs. key-reuse.
  describe 'idempotency' do
    it 'replays the original count for a repeated key + matching fingerprint' do
      first  = increment(guest, key: 'k1', fingerprint: 'fp')
      replay = increment(guest, key: 'k1', fingerprint: 'fp')

      expect(count_of(replay)).to eq(count_of(first))
      expect(replay.replayed?).to be(true)
    end

    it 'does not change the stored count on replay' do
      increment(guest, key: 'k1', fingerprint: 'fp')
      increment(guest, key: 'k1', fingerprint: 'fp')
      after = increment(guest, key: 'k2', fingerprint: 'fp')

      expect(count_of(after)).to eq(2)
    end

    it 'raises KeyReused when a known key is used with a different fingerprint' do
      increment(guest, key: 'k1', fingerprint: 'fp-a')

      expect do
        increment(guest, key: 'k1', fingerprint: 'fp-b')
      end.to raise_error(GreeterHttp::Ports::GreetingCounter::KeyReused)
    end

    it 'rejects a nil fingerprint as a programming error' do
      expect do
        increment(guest, key: 'k1', fingerprint: nil)
      end.to raise_error(ArgumentError)
    end
  end
end
