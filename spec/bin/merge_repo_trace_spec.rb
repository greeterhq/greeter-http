# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# Runs bin/merge-repo-trace as a subprocess (argv form), the way the CI
# `functional` job calls it: bin/merge-repo-trace OUT IN_A IN_B.
RSpec.describe 'bin/merge-repo-trace' do
  let(:repo_root) { File.expand_path('../..', __dir__) }
  let(:script) { File.join(repo_root, 'bin', 'merge-repo-trace') }
  let(:workdir) { Dir.mktmpdir('merge-repo-trace') }
  let(:out_path) { File.join(workdir, 'repo-trace.json') }
  let(:spec_path) { File.join(workdir, 'repo-trace-spec.json') }
  let(:bdd_path) { File.join(workdir, 'repo-trace-bdd.json') }
  let(:sha) { 'a' * 40 }

  let(:rspec_result) do
    { 'requirement' => 'the-api-is-described-by-openapi-yaml', 'scenario' => 'the-request-is-described',
      'status' => 'passed', 'source' => 'rspec', 'location' => 'spec/openapi_description_spec.rb:20' }
  end
  let(:cucumber_result) do
    { 'requirement' => 'greet-a-guest-and-return-a-running-count', 'scenario' => 'first-greeting-for-a-new-guest',
      'status' => 'failed', 'source' => 'cucumber', 'location' => 'features/greeting_counter.feature:13' }
  end

  after { FileUtils.remove_entry(workdir) }

  def document(results, **fields)
    { 'schema' => 'greeterhq.repo-trace.v1', 'repo' => 'greeter-http', 'sha' => sha,
      'recorded_at' => '2026-11-18T10:00:00Z', 'run_id' => '123', 'results' => results }
      .merge(fields.transform_keys(&:to_s))
  end

  def merge(spec_doc, bdd_doc)
    File.write(spec_path, JSON.generate(spec_doc))
    File.write(bdd_path, JSON.generate(bdd_doc))
    Open3.capture3(RbConfig.ruby, script, out_path, spec_path, bdd_path)
  end

  def expect_refused(spec_doc, bdd_doc, naming:)
    _out, err, status = merge(spec_doc, bdd_doc)

    expect(status).not_to be_success
    # Match without the script's own path: 'merge-repo-trace' would otherwise
    # satisfy naming: 'repo'. The failure message still shows the whole stderr,
    # path included, so a missing script is named in the red output.
    unnamed = Array(naming).reject { |text| err.gsub(script, '').include?(text) }
    expect(unnamed).to be_empty, "stderr does not name #{unnamed} (wanted #{Array(naming)}); stderr was #{err.inspect}"
    expect(File).not_to exist(out_path)
  end

  it 'exists and is executable' do
    expect(File.executable?(script)).to be(true), "#{script} is missing or not executable"
  end

  describe 'merging',
           requirement: 'the-rspec-and-cucumber-traces-merge-into-one-trace',
           scenario: 'merge-combines-both-traces' do
    it 'exits 0 and keeps the shared fields, the later recorded_at and every result', :aggregate_failures do
      _out, err, status = merge(document([rspec_result], recorded_at: '2026-11-18T10:05:00Z'),
                                document([cucumber_result]))

      expect([status.success?, err]).to eq([true, ''])
      merged = JSON.parse(File.read(out_path))
      expect(merged).to eq(document([cucumber_result, rspec_result], recorded_at: '2026-11-18T10:05:00Z'))
    end

    it 'accepts a null run_id when both inputs have one', :aggregate_failures do
      _out, _err, status = merge(document([rspec_result], run_id: nil), document([cucumber_result], run_id: nil))

      expect(status).to be_success
      expect(JSON.parse(File.read(out_path))['run_id']).to be_nil
    end
  end

  describe 'mismatched inputs',
           requirement: 'the-rspec-and-cucumber-traces-merge-into-one-trace',
           scenario: 'merge-rejects-mismatched-inputs' do
    { 'sha' => 'b' * 40, 'run_id' => '124' }.each do |field, other|
      it "refuses inputs whose #{field} differs, naming #{field}" do
        expect_refused(document([rspec_result]), document([cucumber_result], field.to_sym => other), naming: field)
      end
    end

    it 'refuses one null and one non-null run_id, naming run_id' do
      expect_refused(document([rspec_result], run_id: nil), document([cucumber_result]), naming: 'run_id')
    end

    it 'refuses the null run_id in the second input, naming run_id' do
      expect_refused(document([rspec_result]), document([cucumber_result], run_id: nil), naming: 'run_id')
    end

    it 'refuses inputs whose schema differs, naming schema' do
      expect_refused(document([rspec_result]), document([cucumber_result], schema: 'greeterhq.repo-trace.v2'),
                     naming: 'schema')
    end

    it 'refuses inputs whose repo differs, naming repo' do
      expect_refused(document([rspec_result]), document([cucumber_result], repo: 'greeter-cli'), naming: 'repo')
    end
  end

  describe 'inputs outside the v1 shape',
           requirement: 'the-rspec-and-cucumber-traces-merge-into-one-trace',
           scenario: 'merge-rejects-inputs-outside-the-v1-shape' do
    it 'refuses an unknown top-level key in either input, naming the file and key', :aggregate_failures do
      expect_refused(document([rspec_result], extra: 'x'), document([cucumber_result]),
                     naming: [File.basename(spec_path), 'extra'])
      expect_refused(document([rspec_result]), document([cucumber_result], extra: 'x'),
                     naming: [File.basename(bdd_path), 'extra'])
    end

    {
      'an extra result key' => ['description', 'Alice Smith'],
      'a status outside the four' => %w[status broken],
      'a source other than rspec or cucumber' => %w[source junit],
      'a requirement that is not a slug' => ['requirement', 'Not A Slug'],
      'a scenario that is not a slug' => %w[scenario Not_A_Slug]
    }.each do |label, (key, value)|
      it "refuses #{label} in an rspec result, naming the file and #{key}" do
        expect_refused(document([rspec_result.merge(key => value)]), document([cucumber_result]),
                       naming: [File.basename(spec_path), key])
      end

      it "refuses #{label} in a cucumber result, naming the file and #{key}" do
        expect_refused(document([rspec_result]), document([cucumber_result.merge(key => value)]),
                       naming: [File.basename(bdd_path), key])
      end
    end

    it 'refuses a feature location for source rspec, naming the file and location' do
      expect_refused(document([rspec_result.merge('location' => 'features/greeting_counter.feature:4')]),
                     document([cucumber_result]), naming: [File.basename(spec_path), 'location'])
    end

    it 'refuses a spec location for source cucumber, naming the file and location' do
      expect_refused(document([rspec_result]), document([cucumber_result.merge('location' => 'spec/x_spec.rb:4')]),
                     naming: [File.basename(bdd_path), 'location'])
    end

    # S8: locations must stay inside spec/ or features/.
    {
      'a .. segment' => ['spec/../etc/x.rb:1', 'features/../etc/x.feature:1'],
      'a . segment' => ['spec/./x.rb:1', 'features/./x.feature:1'],
      'an empty segment' => ['spec//x.rb:1', 'features//x.feature:1'],
      'a leading slash' => ['/spec/x.rb:1', '/features/x.feature:1'],
      'line 0' => ['spec/x.rb:0', 'features/x.feature:0']
    }.each do |label, (rspec_location, cucumber_location)|
      it "refuses a location with #{label} in either input, naming the file and location", :aggregate_failures do
        expect_refused(document([rspec_result.merge('location' => rspec_location)]), document([cucumber_result]),
                       naming: [File.basename(spec_path), 'location'])
        expect_refused(document([rspec_result]), document([cucumber_result.merge('location' => cucumber_location)]),
                       naming: [File.basename(bdd_path), 'location'])
      end
    end

    it 'accepts a valid nested spec location' do
      _out, _err, status = merge(document([rspec_result.merge('location' => 'spec/adapters/x_spec.rb:12')]),
                                 document([cucumber_result]))

      expect(status).to be_success
    end

    # S9: top-level values are validated, not only compared, so two inputs
    # carrying the same bad value are still refused.
    {
      'sha' => 'not-a-sha',
      'run_id' => '12a',
      'recorded_at' => 'last tuesday',
      'schema' => 'greeterhq.repo-trace.v2',
      'repo' => 'greeter-cli'
    }.each do |field, value|
      it "refuses a malformed #{field} even when both inputs agree, naming #{field}" do
        expect_refused(document([rspec_result], field.to_sym => value),
                       document([cucumber_result], field.to_sym => value), naming: field)
      end
    end
  end

  describe 'duplicated results',
           requirement: 'the-rspec-and-cucumber-traces-merge-into-one-trace',
           scenario: 'merge-rejects-a-duplicated-result' do
    it 'refuses a result present in both inputs, naming its requirement and location' do
      expect_refused(document([rspec_result]), document([cucumber_result, rspec_result]),
                     naming: [rspec_result['requirement'], rspec_result['location']])
    end
  end
end
