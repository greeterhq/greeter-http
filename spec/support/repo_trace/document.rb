# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'

module RepoTrace
  # The greeterhq.repo-trace.v1 document, shared by the RSpec formatter, the
  # Cucumber writer and bin/merge-repo-trace. Every value is checked against a
  # fixed pattern before it is written, because greeter-docs renders the file.
  # Errors name the field and never echo the value (it may be a guest name).
  module Document
    class Invalid < StandardError; end

    SCHEMA = 'greeterhq.repo-trace.v1'
    REPO = 'greeter-http'
    SLUG = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    # Each path segment starts with a word character or '-', so '.', '..',
    # empty segments and absolute paths are rejected.
    LOCATIONS = {
      'rspec' => %r{\Aspec(?:/[\w-][\w.-]*)+\.rb:[1-9]\d*\z},
      'cucumber' => %r{\Afeatures(?:/[\w-][\w.-]*)+\.feature:[1-9]\d*\z}
    }.freeze
    SHA = /\A[0-9a-f]{40}\z/
    RUN_ID = /\A\d+\z/
    RECORDED_AT = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
    # Worst first: duplicates collapse to the lowest rank.
    STATUS_RANK = { 'failed' => 0, 'pending' => 1, 'skipped' => 2, 'passed' => 3 }.freeze
    TOP_KEYS = %w[schema repo sha recorded_at run_id results].freeze
    RESULT_KEYS = %w[requirement scenario status source location].freeze

    module_function

    def result(requirement:, scenario:, status:, source:, location:)
      check('requirement', requirement) { |value| SLUG.match?(value) }
      check('scenario', scenario) { |value| SLUG.match?(value) }
      check('status', status) { |value| STATUS_RANK.key?(value) }
      check('source', source) { |value| LOCATIONS.key?(value) }
      check('location', location) { |value| LOCATIONS.fetch(source).match?(value) }
      { 'requirement' => requirement, 'scenario' => scenario, 'status' => status,
        'source' => source, 'location' => location }
    end

    def header(sha:, run_id:, recorded_at:)
      check('sha', sha) { |value| SHA.match?(value) }
      raise Invalid, 'invalid run_id' unless run_id.nil? || (run_id.is_a?(String) && RUN_ID.match?(run_id))

      check('recorded_at', recorded_at) { |value| RECORDED_AT.match?(value) }
      { 'schema' => SCHEMA, 'repo' => REPO, 'sha' => sha, 'recorded_at' => recorded_at, 'run_id' => run_id }
    end

    # Validates a parsed document in full: exact keys, fixed schema and repo,
    # well-formed run metadata and every result.
    def validate(document)
      raise Invalid, 'invalid document' unless document.is_a?(Hash)

      check_keys('key', document, TOP_KEYS)
      validate_header(document)
      raise Invalid, 'invalid results' unless document['results'].is_a?(Array)

      document['results'].each { |entry| validate_result(entry) }
      document
    end

    def validate_header(document)
      raise Invalid, 'invalid schema' unless document['schema'] == SCHEMA
      raise Invalid, 'invalid repo' unless document['repo'] == REPO

      header(**document.slice('sha', 'run_id', 'recorded_at').transform_keys(&:to_sym))
    end

    def validate_result(entry)
      raise Invalid, 'invalid result' unless entry.is_a?(Hash)

      check_keys('result key', entry, RESULT_KEYS)
      result(**entry.transform_keys(&:to_sym))
    end

    def key(result)
      result.values_at('requirement', 'scenario', 'location')
    end

    # One result per (requirement, scenario, location), keeping the worst status.
    def collapse(results)
      results.group_by { |result| key(result) }.values.map do |group|
        group.min_by { |result| STATUS_RANK.fetch(result['status']) }
      end
    end

    def sort(results)
      results.sort_by do |result|
        file, line = result['location'].split(':')
        [file, line.to_i, result['requirement'], result['scenario']]
      end
    end

    # Builds the document from validated results and writes it. The env, clock
    # and root are injected so callers (and their specs) control them.
    def write(path:, results:, env: ENV, clock: -> { Time.now }, root: Dir.pwd)
      document = header(sha: env['GITHUB_SHA'] || git_head(root), run_id: env['GITHUB_RUN_ID'],
                        recorded_at: clock.call.utc.strftime('%Y-%m-%dT%H:%M:%SZ'))
      document['results'] = sort(collapse(results))
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(document)}\n")
    end

    # A runner-reported path as a repo-relative path: './spec/x.rb' or
    # '/abs/root/spec/x.rb' -> 'spec/x.rb'.
    def relative(path, root)
      path = path.to_s.delete_prefix('./')
      prefix = File.join(File.expand_path(root), '')
      path.start_with?(prefix) ? path.delete_prefix(prefix) : path
    end

    def git_head(root)
      out, status = Open3.capture2('git', 'rev-parse', 'HEAD', chdir: root)
      status.success? ? out.strip : nil
    end

    def check(field, value)
      raise Invalid, "invalid #{field}" unless value.is_a?(String) && yield(value)
    end

    def check_keys(label, hash, allowed)
      extra = hash.keys - allowed
      raise Invalid, "invalid #{label} #{extra.first}" if extra.any?

      missing = allowed - hash.keys
      raise Invalid, "missing #{label} #{missing.first}" if missing.any?
    end
  end
end
