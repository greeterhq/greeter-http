# frozen_string_literal: true

require 'spec_helper'

# RepoTrace::Document is copied into spec/support/repo_trace/ by the
# implementation group. It is required here only when it exists, so that before
# then this file loads and fails with a NameError in each example.
document_support = File.expand_path('../support/repo_trace/document.rb', __dir__)
require document_support if File.exist?(document_support)

# RepoTrace::Document holds the validation both writers (RSpec formatter and
# Cucumber writer) and bin/merge-repo-trace go through. Locations come from the
# test runners and cannot be forced to contain '..' through a real run, so the
# location rules (S8) are tested here, at the shared document.
RSpec.describe 'RepoTrace::Document',
               requirement: 'repo-trace-contains-only-slugs-statuses-locations-and-run-metadata',
               scenario: 'writers-refuse-malformed-values' do
  # String keys, so the trace check's text scan does not read these values as tags.
  def result(**overrides)
    valid = { 'requirement' => 'greet-a-guest-and-return-a-running-count',
              'scenario' => 'first-greeting-for-a-new-guest',
              'status' => 'passed', 'source' => 'rspec', 'location' => 'spec/adapters/x_spec.rb:12' }
    RepoTrace::Document.result(**valid.transform_keys(&:to_sym), **overrides)
  end

  it 'accepts a nested spec location for rspec' do
    expect(result).to eq('requirement' => 'greet-a-guest-and-return-a-running-count',
                         'scenario' => 'first-greeting-for-a-new-guest',
                         'status' => 'passed', 'source' => 'rspec', 'location' => 'spec/adapters/x_spec.rb:12')
  end

  it 'accepts a feature location for cucumber' do
    expect(result(source: 'cucumber', location: 'features/greeting_counter.feature:13')['location'])
      .to eq('features/greeting_counter.feature:13')
  end

  it 'accepts all four statuses' do
    statuses = %w[passed failed pending skipped].map { |status| result(status: status)['status'] }

    expect(statuses).to eq(%w[passed failed pending skipped])
  end

  {
    'a .. segment' => ['rspec', 'spec/../etc/x.rb:1'],
    'a . segment' => ['rspec', 'spec/./x.rb:1'],
    'an empty segment' => ['rspec', 'spec//x.rb:1'],
    'a leading slash' => ['rspec', '/spec/x.rb:1'],
    'line 0' => ['rspec', 'spec/x.rb:0'],
    'no line' => ['rspec', 'spec/x.rb'],
    'a feature path for rspec' => ['rspec', 'features/greeting_counter.feature:3'],
    'a spec path for cucumber' => ['cucumber', 'spec/x_spec.rb:3'],
    'a .. segment in a feature path' => ['cucumber', 'features/../x.feature:2'],
    'an empty location' => ['rspec', '']
  }.each do |label, (source, location)|
    it "refuses a location with #{label}, without echoing it", :aggregate_failures do
      expect { result(source: source, location: location) }
        .to raise_error(RepoTrace::Document::Invalid) { |error|
          expect(error.message).to start_with('invalid location')
          expect(error.message).not_to include(location) unless location.empty?
        }
    end
  end

  # String keys, so the trace check's text scan does not read these bad values as tags.
  {
    'requirement' => 'Alice Smith',
    'scenario' => 'Not_A_Slug',
    'status' => 'broken',
    'source' => 'junit'
  }.each do |field, value|
    it "refuses an invalid #{field}, without echoing it", :aggregate_failures do
      expect { result(field.to_sym => value) }
        .to raise_error(RepoTrace::Document::Invalid) { |error|
          expect(error.message).to start_with("invalid #{field}")
          expect(error.message).not_to include(value)
        }
    end
  end

  it 'refuses a value that is not a string, naming the field' do
    expect { result(requirement: 42) }.to raise_error(RepoTrace::Document::Invalid, /\Ainvalid requirement/)
  end

  describe 'the run metadata' do
    let(:sha) { '0123456789abcdef0123456789abcdef01234567' }

    it 'accepts a 40 hex sha, digits or null for run_id and a UTC second timestamp' do
      header = RepoTrace::Document.header(sha: sha, run_id: nil, recorded_at: '2026-11-18T10:00:00Z')

      expect(header).to eq('schema' => 'greeterhq.repo-trace.v1', 'repo' => 'greeter-http', 'sha' => sha,
                           'recorded_at' => '2026-11-18T10:00:00Z', 'run_id' => nil)
    end

    {
      'sha' => { sha: 'not-a-sha', run_id: '1', recorded_at: '2026-11-18T10:00:00Z' },
      'run_id' => { sha: '0123456789abcdef0123456789abcdef01234567', run_id: '12a',
                    recorded_at: '2026-11-18T10:00:00Z' },
      'recorded_at' => { sha: '0123456789abcdef0123456789abcdef01234567', run_id: '1', recorded_at: 'last tuesday' }
    }.each do |field, arguments|
      it "refuses a malformed #{field}, naming it" do
        expect { RepoTrace::Document.header(**arguments) }
          .to raise_error(RepoTrace::Document::Invalid, /\Ainvalid #{field}/)
      end
    end
  end
end
