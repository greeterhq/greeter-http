# frozen_string_literal: true

require_relative '../../spec/support/repo_trace/document'

# Cucumber writer for the greeterhq.repo-trace.v1 file read by greeter-docs.
# Records each scenario tagged with one @requirement-<slug> and one
# @scenario-<slug>, and writes REPO_TRACE_PATH (default tmp/repo-trace-bdd.json)
# once, after the run. It reads only tags, status and location, never the
# scenario name or step text. A malformed value raises, and then nothing is
# written. It replaces the old traceability.rb, which wrote a bare array.
module RepoTraceCucumber
  DEFAULT_PATH = 'tmp/repo-trace-bdd.json'
  STATUSES = { passed: 'passed', failed: 'failed', pending: 'pending', undefined: 'pending',
               skipped: 'skipped' }.freeze

  # Cucumber hooks share no instance between scenarios, so the run's results
  # live on this module for the length of one process.
  @results = []
  @invalid = false

  class << self
    def record(scenario)
      requirement = tag_value(scenario, '@requirement-')
      slug = tag_value(scenario, '@scenario-')
      return unless requirement && slug

      @results << RepoTrace::Document.result(
        requirement: requirement, scenario: slug, status: STATUSES.fetch(scenario.status, 'failed'),
        source: 'cucumber', location: RepoTrace::Document.relative(scenario.location.to_s, Dir.pwd)
      )
    rescue RepoTrace::Document::Invalid => e
      @invalid = true
      fail_with(e)
    end

    def write
      return if @invalid

      RepoTrace::Document.write(path: ENV.fetch('REPO_TRACE_PATH', DEFAULT_PATH), results: @results)
    rescue RepoTrace::Document::Invalid => e
      fail_with(e)
    end

    # Cucumber's progress output does not show hook errors, so name the field
    # on stderr too. The message never contains the rejected value.
    def fail_with(error)
      warn("repo-trace: #{error.message}")
      raise error
    end

    private

    def tag_value(scenario, prefix)
      values = scenario.source_tag_names.select { |tag| tag.start_with?(prefix) }
      values.first.delete_prefix(prefix) if values.size == 1
    end
  end
end

After do |scenario|
  RepoTraceCucumber.record(scenario)
end

AfterAll do
  RepoTraceCucumber.write
end
