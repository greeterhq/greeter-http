# frozen_string_literal: true

require 'spec_helper'

# RepoTrace::Check and RepoTrace::Slug are copied into spec/support/repo_trace/
# by the implementation group. They are required here only when they exist, so
# that before then this file loads and fails with a NameError in each example.
%w[slug check].each do |name|
  support = File.expand_path("support/repo_trace/#{name}.rb", __dir__)
  require support if File.exist?(support)
end

# The trace check reads OpenSpec markdown and test files as text (no Node, no
# OpenSpec CLI). Fixture cases run against spec/fixtures/trace_check/; the last
# examples run the same check on this repository.
RSpec.describe 'trace check' do
  let(:repo_root) { File.expand_path('..', __dir__) }
  let(:fixtures) { File.join(repo_root, 'spec', 'fixtures', 'trace_check') }

  def run_check(examples: ['examples/base.rb'], features: ['features/base.feature'])
    RepoTrace::Check.call(
      spec_glob: File.join(fixtures, 'specs/**/spec.md'),
      change_glob: File.join(fixtures, 'changes/**/specs/**/spec.md'),
      example_glob: File.join(fixtures, "{#{examples.join(',')}}"),
      feature_glob: File.join(fixtures, "{#{features.join(',')}}"),
      exclude_glob: File.join(fixtures, 'excluded/**/*')
    )
  end

  def problems_naming(problems, text)
    problems.select { |problem| problem.include?(text) }
  end

  describe 'a requirement with no tagged test',
           requirement: 'every-requirement-has-a-tagged-test',
           scenario: 'requirement-with-no-tagged-test-fails-and-is-named' do
    it 'reports only the uncovered requirement when everything else is tagged' do
      expect(run_check).to contain_exactly(a_string_including('"uncovered-requirement"'))
    end

    it 'names the requirement and its spec file', :aggregate_failures do
      problem = problems_naming(run_check, 'uncovered-requirement').first
      expect(problem).to include('has no tagged test')
      expect(problem).to include('specs/alpha/spec.md')
    end
  end

  describe 'features/greeting_counter.feature',
           requirement: 'every-requirement-has-a-tagged-test',
           scenario: 'greeting-counter-scenarios-are-tagged-one-to-one' do
    let(:feature_path) { File.join(repo_root, 'features', 'greeting_counter.feature') }
    let(:lines) { File.readlines(feature_path, chomp: true) }
    let(:scenario_indexes) { lines.each_index.select { |index| lines[index].match?(/\A\s*Scenario:/) } }

    # The tag line directly above each Scenario: line.
    def tags_above(index)
      lines[index - 1].to_s.strip.split(/\s+/)
    end

    it 'has 13 scenarios, each with exactly one requirement tag and one scenario tag', :aggregate_failures do
      expect(scenario_indexes.size).to eq(13)
      scenario_indexes.each do |index|
        tags = tags_above(index)
        expect(tags.grep(/\A@requirement-/).size).to eq(1), "line #{index + 1} needs one @requirement- tag"
        expect(tags.grep(/\A@scenario-/).size).to eq(1), "line #{index + 1} needs one @scenario- tag"
      end
    end

    it 'has no feature-level @requirement- tag' do
      feature_line = lines.index { |line| line.start_with?('Feature:') }

      expect(lines.first(feature_line).grep(/@requirement-/)).to be_empty
    end

    it 'covers all seven greeting-counter requirements and every tag matches a heading' do
      problems = RepoTrace::Check.call(
        spec_glob: File.join(repo_root, 'openspec/specs/greeting-counter/spec.md'),
        change_glob: File.join(fixtures, 'no-changes/**/spec.md'),
        example_glob: File.join(fixtures, 'no-examples/**/*.rb'),
        feature_glob: feature_path
      )

      expect(problems).to be_empty
    end

    it 'tags every scenario with the requirement slug of the heading it is named after', :aggregate_failures do
      by_requirement = scenario_indexes.group_by { |index| tags_above(index).grep(/\A@requirement-/).first }

      expect(by_requirement.size).to eq(7)
      expect(by_requirement.transform_values(&:size).values.sort).to eq([1, 1, 1, 2, 2, 3, 3])
    end
  end

  # Design rule: each Cucumber scenario carries exactly one @requirement- and one
  # @scenario- tag. Not an OpenSpec scenario of its own, so left untagged.
  it 'reports a feature scenario that has a requirement tag but no scenario tag' do
    problems = run_check(features: %w[features/base.feature features/missing_scenario_tag.feature])

    expect(problems_naming(problems, 'features/missing_scenario_tag.feature:4')).not_to be_empty
  end

  describe 'an unknown requirement slug',
           requirement: 'tagged-tests-must-match-a-requirement-and-scenario',
           scenario: 'unknown-requirement-slug-fails-and-is-named' do
    it 'names the slug and the RSpec example file and line', :aggregate_failures do
      problem = problems_naming(run_check(examples: %w[examples/base.rb examples/unknown.rb]),
                                'no-such-requirement').first
      expect(problem).to include('matches no requirement heading')
      expect(problem).to include('examples/unknown.rb:5')
    end

    it 'names the slug and the feature file and Scenario line', :aggregate_failures do
      problem = problems_naming(run_check(features: %w[features/base.feature features/unknown.feature]),
                                'no-such-requirement').first
      expect(problem).to include('matches no requirement heading')
      expect(problem).to include('features/unknown.feature:4')
    end
  end

  describe 'scenario slugs',
           requirement: 'tagged-tests-must-match-a-requirement-and-scenario',
           scenario: 'scenario-slug-is-matched-only-within-its-requirement' do
    it 'rejects a scenario that belongs to a different requirement', :aggregate_failures do
      problem = problems_naming(run_check(examples: %w[examples/base.rb examples/wrong_scenario.rb]),
                                'examples/wrong_scenario.rb').first
      expect(problem).to include('is not a scenario of requirement')
      expect(problem).to include('"only-under-other"').and include('"covered-requirement"')
    end

    it 'accepts a scenario slug equal to its requirement slug' do
      expect(problems_naming(run_check, 'same-text-scenario')).to be_empty
    end
  end

  describe 'change deltas',
           requirement: 'tagged-tests-must-match-a-requirement-and-scenario',
           scenario: 'requirements-in-in-flight-changes-are-known' do
    let(:problems) { run_check(examples: %w[examples/base.rb examples/in_flight.rb]) }

    it 'knows ADDED requirements and MODIFIED scenarios of changes that are not archived', :aggregate_failures do
      expect(problems_naming(problems, 'added-in-flight')).to be_empty
      expect(problems_naming(problems, 'modified-extra-scenario')).to be_empty
    end

    it 'treats archived, REMOVED and RENAMED headings as unknown, naming file and line', :aggregate_failures do
      %w[archived-only removed-requirement new-name].each do |slug|
        expect(problems_naming(problems, "\"#{slug}\"")).to contain_exactly(match(%r{examples/in_flight\.rb:\d+}))
      end
    end
  end

  describe 'excluded files',
           requirement: 'tagged-tests-must-match-a-requirement-and-scenario',
           scenario: 'fixture-files-are-not-scanned' do
    it 'never reads tags from files matched by the exclude glob' do
      problems = run_check(examples: %w[examples/base.rb excluded/ignored.rb])

      expect(problems_naming(problems, 'excluded-unknown-requirement')).to be_empty
    end

    it 'reports no problem from spec/fixtures/** and none for any real file in this repository' do
      problems = RepoTrace::Check.call(
        spec_glob: File.join(repo_root, 'openspec/specs/**/spec.md'),
        change_glob: File.join(repo_root, 'openspec/changes/**/specs/**/spec.md'),
        example_glob: File.join(repo_root, 'spec/**/*.rb'),
        feature_glob: File.join(repo_root, 'features/**/*.feature'),
        exclude_glob: File.join(repo_root, 'spec/fixtures/**/*')
      )

      expect(problems).to be_empty
    end
  end
end
