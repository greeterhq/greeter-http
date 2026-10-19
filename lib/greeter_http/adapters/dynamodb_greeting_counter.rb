# frozen_string_literal: true

require 'aws-sdk-dynamodb'
require 'greeter_http/ports/greeting_counter'

module GreeterHttp
  module Adapters
    # DynamoDB-backed GreetingCounter.
    #
    # Single table, two item types sharing a guest partition:
    #   COUNTER item  PK="GUEST#<display>" SK="COUNTER"  { count, updated_at }
    #   DEDUPE item   PK="GUEST#<display>" SK="IKEY#<key>"
    #                 { fingerprint, count_snapshot, greeted_at, created_at, expires_at(TTL) }
    #
    # Write path (Option 1 - optimistic lock, exact snapshot, never transiently
    # wrong): read current count, then a single TransactWriteItems that both
    # Puts the dedupe item (condition: key not seen) and Updates the counter
    # (condition: count unchanged since read). A cancellation is classified by
    # reason: dedupe-condition-failed => replay (or KeyReused on fingerprint
    # mismatch); counter-condition-failed => concurrent writer, retry; anything
    # transient => Unavailable.
    class DynamoDbGreetingCounter < Ports::GreetingCounter
      DEFAULT_TTL_SECONDS = 86_400
      MAX_RETRIES = 25
      BASE_BACKOFF_SECONDS = 0.005
      MAX_BACKOFF_SECONDS = 0.25

      def initialize(client:, table_name:, ttl_seconds: DEFAULT_TTL_SECONDS, clock: SystemClock.new)
        super()
        @client = client
        @table_name = table_name
        @ttl_seconds = ttl_seconds
        @clock = clock
      end

      def increment(guest:, idempotency_key:, fingerprint:, synthetic: false)
        validate_arguments!(idempotency_key: idempotency_key, fingerprint: fingerprint)
        # Synthetic (monitoring) traffic is isolated under a "synthetic#" PK
        # prefix so canary greetings never inflate real per-guest counts.
        pk = "#{'synthetic#' if synthetic}GUEST##{guest}"
        attempt = 0

        loop do
          attempt += 1
          begin
            return attempt_increment(pk, idempotency_key, fingerprint)
          rescue Aws::DynamoDB::Errors::TransactionCanceledException => e
            outcome = classify_cancellation(e)
            # A lost optimistic-lock race on the counter is retried with backoff
            # until the budget is exhausted; the count stays exact.
            return replay(pk, idempotency_key, fingerprint) if outcome == :replay
            raise Unavailable, 'greeting counter transaction cancelled' unless outcome == :contended
            raise Unavailable, 'greeting counter contention exceeded retries' if attempt >= MAX_RETRIES

            backoff(attempt)
          rescue Aws::DynamoDB::Errors::ServiceError => e
            raise Unavailable, "greeting counter store unavailable: #{e.class}"
          end
        end
      end

      private

      def read_count(pk)
        resp = @client.get_item(
          table_name: @table_name,
          key: { 'PK' => pk, 'SK' => 'COUNTER' },
          consistent_read: true
        )
        resp.item ? resp.item.fetch('count').to_i : 0
      end

      def dedupe_put(pk, key, fingerprint, new_count, now)
        {
          put: {
            table_name: @table_name,
            item: {
              'PK' => pk,
              'SK' => "IKEY##{key}",
              'fingerprint' => fingerprint,
              'count_snapshot' => new_count,
              'greeted_at' => now.utc.iso8601,
              'created_at' => now.utc.iso8601,
              'expires_at' => now.to_i + @ttl_seconds
            },
            condition_expression: 'attribute_not_exists(SK)'
          }
        }
      end

      def counter_update(pk, current, new_count, now)
        if current.zero?
          {
            update: {
              table_name: @table_name,
              key: { 'PK' => pk, 'SK' => 'COUNTER' },
              update_expression: 'SET #c = :new, updated_at = :now',
              condition_expression: 'attribute_not_exists(#c)',
              expression_attribute_names: { '#c' => 'count' },
              expression_attribute_values: { ':new' => new_count, ':now' => now.utc.iso8601 }
            }
          }
        else
          {
            update: {
              table_name: @table_name,
              key: { 'PK' => pk, 'SK' => 'COUNTER' },
              update_expression: 'SET #c = :new, updated_at = :now',
              condition_expression: '#c = :current',
              expression_attribute_names: { '#c' => 'count' },
              expression_attribute_values: {
                ':new' => new_count, ':current' => current, ':now' => now.utc.iso8601
              }
            }
          }
        end
      end

      # One read + one optimistic-lock transaction. Raises
      # TransactionCanceledException on a lost race or a seen key.
      def attempt_increment(pk, key, fingerprint)
        current = read_count(pk)
        new_count = current + 1
        now = @clock.now

        @client.transact_write_items(
          transact_items: [
            dedupe_put(pk, key, fingerprint, new_count, now),
            counter_update(pk, current, new_count, now)
          ]
        )
        Result.new(count: new_count, replayed: false)
      end

      # Classify a cancellation by its positional reasons, matching
      # transact_items order: [0] = dedupe Put, [1] = counter Update.
      #   :replay    - dedupe key already present (idempotent retry)
      #   :contended - another writer moved the counter; retry with backoff
      #   :other     - unexpected cancellation
      def classify_cancellation(error)
        reasons = cancellation_reasons(error)
        return :replay if reasons[0] == 'ConditionalCheckFailed'
        return :contended if reasons[1] == 'ConditionalCheckFailed'

        :other
      end

      def cancellation_reasons(error)
        if error.respond_to?(:cancellation_reasons) && error.cancellation_reasons
          error.cancellation_reasons.map { |r| r.respond_to?(:code) ? r.code : r['Code'] }
        else
          []
        end
      end

      # Exponential backoff with full jitter to de-synchronize concurrent
      # writers contending on the same counter.
      def backoff(attempt)
        base = BASE_BACKOFF_SECONDS * (2**(attempt - 1))
        sleep(rand * [base, MAX_BACKOFF_SECONDS].min)
      end

      def replay(pk, key, fingerprint)
        resp = @client.get_item(
          table_name: @table_name,
          key: { 'PK' => pk, 'SK' => "IKEY##{key}" },
          consistent_read: true
        )
        item = resp.item
        raise Unavailable, 'dedupe record vanished during replay' unless item

        unless item['fingerprint'] == fingerprint
          raise KeyReused, 'idempotency key already used for a different request'
        end

        Result.new(count: item.fetch('count_snapshot').to_i, replayed: true)
      end
    end
  end
end
