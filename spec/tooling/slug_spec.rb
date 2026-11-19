# frozen_string_literal: true

require 'spec_helper'

# RepoTrace::Slug is copied into spec/support/repo_trace/ by the implementation
# group. It is required here only when it exists, so that before then this file
# loads and fails with a NameError inside each example.
slug_support = File.expand_path('../support/repo_trace/slug.rb', __dir__)
require slug_support if File.exist?(slug_support)

# Every slug below is written out by hand. None is computed with the function
# under test, so a wrong rule cannot agree with itself.
RSpec.describe 'RepoTrace::Slug',
               requirement: 'every-requirement-has-a-tagged-test',
               scenario: 'slug-rule-turns-headings-into-slugs' do
  {
    'Greet a guest and return a running count' => 'greet-a-guest-and-return-a-running-count',
    'Replaying an idempotency key returns the original result' =>
      'replaying-an-idempotency-key-returns-the-original-result',
    'Names differing only by case or whitespace share a count' =>
      'names-differing-only-by-case-or-whitespace-share-a-count',
    'Gate ref and acceptance_ref must agree' => 'gate-ref-and-acceptance-ref-must-agree',
    'Hostile tag text is not echoed' => 'hostile-tag-text-is-not-echoed',
    'Surfaces control/escape characters as an error' => 'surfaces-control-escape-characters-as-an-error',
    'Clock#now raises NotImplementedError' => 'clock-now-raises-notimplementederror',
    'Completes #greet in under 5 ms at p99' => 'completes-greet-in-under-5-ms-at-p99',
    'Equal names agree across ==, eql?, hash, and uniq' => 'equal-names-agree-across-eql-hash-and-uniq',
    'Unrouted requests carry version headers' => 'unrouted-requests-carry-version-headers',
    '  --Leading and trailing!!  ' => 'leading-and-trailing'
  }.each do |heading, slug|
    it "turns #{heading.inspect} into #{slug}" do
      expect(RepoTrace::Slug.call(heading)).to eq(slug)
    end
  end

  describe 'every real heading' do
    # Main specs and the specs of changes that are not archived, one entry per
    # spec.md: { file => { requirements: [headings], scenarios: [headings] } }.
    # A change's MODIFIED requirement repeats a main-spec heading by design, so
    # uniqueness is checked inside one spec file (one capability), not across files.
    let(:repo_root) { File.expand_path('../..', __dir__) }
    let(:headings_by_file) do
      files = Dir[File.join(repo_root, 'openspec/specs/**/spec.md')] +
              Dir[File.join(repo_root, 'openspec/changes/*/specs/**/spec.md')]
      files.to_h do |file|
        text = File.read(file)
        [file.delete_prefix("#{repo_root}/"),
         { requirements: text.scan(/^### Requirement:\s*(.+?)\s*$/).flatten,
           scenarios: text.scan(/^#### Scenario:\s*(.+?)\s*$/).flatten }]
      end
    end

    it 'finds the real specs to check' do
      expect(headings_by_file.keys).to include('openspec/specs/greeting-counter/spec.md')
      expect(headings_by_file.values.sum { |entry| entry.values.sum(&:size) }).to be > 100
    end

    it 'gives each heading only lowercase letters, digits and single hyphens' do
      slugs = headings_by_file.values.flat_map { |entry| entry.values.flatten }.map { |text| RepoTrace::Slug.call(text) }

      expect(slugs.grep_v(/\A[a-z0-9]+(-[a-z0-9]+)*\z/)).to be_empty
    end

    it 'keeps requirement slugs and scenario slugs unique within each capability' do
      duplicates = headings_by_file.flat_map do |file, entry|
        entry.flat_map do |level, texts|
          slugs = texts.map { |text| RepoTrace::Slug.call(text) }
          slugs.tally.select { |_slug, count| count > 1 }.keys.map { |slug| "#{file} #{level} #{slug}" }
        end
      end

      expect(duplicates).to be_empty
    end
  end
end
