# frozen_string_literal: true

require_relative 'slug'

module RepoTrace
  # Requirement and scenario headings from OpenSpec markdown, as
  # { requirement_slug => { file:, scenarios: Set } }. Main specs count every
  # heading; change deltas count only headings inside ADDED and MODIFIED
  # sections, and a MODIFIED requirement adds its scenarios to the main-spec
  # requirement of the same slug.
  module Headings
    REQUIREMENT = /\A### Requirement:\s*(.+?)\s*\z/
    SCENARIO = /\A#### Scenario:\s*(.+?)\s*\z/
    DELTA_SECTION = /\A## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements\s*\z/
    COUNTED_SECTIONS = %w[ADDED MODIFIED].freeze

    module_function

    def call(spec_glob:, change_glob:)
      known = {}
      Dir.glob(spec_glob).each { |file| read(file, known, delta: false) }
      Dir.glob(change_glob).reject { |file| file.include?('/changes/archive/') }
         .each { |file| read(file, known, delta: true) }
      known
    end

    def read(file, known, delta:)
      state = { section: nil, current: nil }
      File.foreach(file, chomp: true) { |line| read_line(line, file, known, delta, state) }
    end

    def read_line(line, file, known, delta, state)
      section = delta && DELTA_SECTION.match(line)
      return state.update(section: section[1], current: nil) if section

      requirement = REQUIREMENT.match(line)
      return state[:current] = entry(known, requirement[1], file, delta, state) if requirement

      scenario = state[:current] && SCENARIO.match(line)
      state[:current][:scenarios] << Slug.call(scenario[1]) if scenario
    end

    # The requirement's entry when its heading counts here, else nil.
    def entry(known, heading, file, delta, state)
      return nil if delta && !COUNTED_SECTIONS.include?(state[:section])

      known[Slug.call(heading)] ||= { file: file, scenarios: Set.new }
    end
  end

  # Requirement/scenario tags read as text from RSpec files and Cucumber
  # features (the files are never loaded).
  module Tags
    Tag = Struct.new(:requirement, :scenario, :file, :line)
    RSPEC_TAG = /requirement:\s*'([^']+)',\s*scenario:\s*'([^']+)'/
    SCENARIO_LINE = /\A\s*(?:Scenario|Scenario Outline|Example):/

    module_function

    def rspec(files)
      files.flat_map do |file|
        text = File.read(file)
        text.to_enum(:scan, RSPEC_TAG).map do
          match = Regexp.last_match
          Tag.new(match[1], match[2], Check.relative(file), text[0...match.begin(0)].count("\n") + 1)
        end
      end
    end

    # A Cucumber scenario's tags are the feature-level tags plus the tag lines
    # directly above its Scenario: line. Tagged scenarios need exactly one of
    # each kind; anything else is added to problems.
    def features(files, problems)
      files.flat_map do |file|
        state = { feature: [], pending: [] }
        File.readlines(file, chomp: true).each_with_index.filter_map do |line, index|
          feature_line(line, "#{Check.relative(file)}:#{index + 1}", state, problems)
        end
      end
    end

    def feature_line(line, location, state, problems)
      stripped = line.strip
      if stripped.start_with?('@')
        state[:pending].concat(stripped.split(/\s+/))
      elsif stripped.start_with?('Feature:')
        state.update(feature: state[:pending], pending: [])
      elsif SCENARIO_LINE.match?(line)
        return scenario(state[:feature] + take_pending(state), location, problems)
      end
      nil
    end

    def take_pending(state)
      pending = state[:pending]
      state[:pending] = []
      pending
    end

    def scenario(tags, location, problems)
      requirements = values(tags, '@requirement-')
      scenarios = values(tags, '@scenario-')
      return nil if requirements.empty? && scenarios.empty?
      return Tag.new(requirements.first, scenarios.first, *split(location)) if [requirements, scenarios].all?(&:one?)

      problems << "scenario at #{location} needs exactly one @requirement- and one @scenario- tag"
      nil
    end

    def values(tags, prefix)
      tags.select { |tag| tag.start_with?(prefix) }.map { |tag| tag.delete_prefix(prefix) }
    end

    def split(location)
      file, line = location.split(':')
      [file, line.to_i]
    end
  end

  # Finds requirements with no tagged test, and tags that match no
  # requirement or scenario. Text only: no Node, no OpenSpec CLI. Returns a
  # list of problem strings (empty when everything is traced).
  module Check
    module_function

    def call(spec_glob:, change_glob:, example_glob:, feature_glob:, exclude_glob: nil)
      known = Headings.call(spec_glob: spec_glob, change_glob: change_glob)
      excluded = exclude_glob ? Dir.glob(exclude_glob) : []
      problems = []
      tags = Tags.rspec(files(example_glob, excluded)) + Tags.features(files(feature_glob, excluded), problems)
      uncovered(known, tags) + problems + tag_problems(known, tags)
    end

    def files(glob, excluded)
      Dir.glob(glob).reject { |file| excluded.include?(file) || File.directory?(file) }
    end

    def uncovered(known, tags)
      known.except(*tags.map(&:requirement))
           .map { |slug, entry| %(requirement "#{slug}" (#{relative(entry[:file])}) has no tagged test) }
    end

    def tag_problems(known, tags)
      tags.filter_map do |tag|
        where = "#{tag.file}:#{tag.line}"
        entry = known[tag.requirement]
        if entry.nil?
          %(test tagged requirement "#{tag.requirement}" (#{where}) matches no requirement heading)
        elsif tag.scenario != tag.requirement && !entry[:scenarios].include?(tag.scenario)
          %(test scenario "#{tag.scenario}" (#{where}) is not a scenario of requirement "#{tag.requirement}")
        end
      end
    end

    def relative(path)
      path.delete_prefix(File.join(Dir.pwd, ''))
    end
  end
end
