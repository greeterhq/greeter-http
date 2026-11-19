# frozen_string_literal: true

require 'spec_helper'

# The two architecture decision records written by the live-docs change. This
# spec verifies no OpenSpec scenario, so it carries no requirement tag.
RSpec.describe 'architecture decision records' do
  let(:repo_root) { File.expand_path('../..', __dir__) }
  let(:adr_dir) { File.join(repo_root, 'docs', 'adr') }
  let(:expected) do
    %w[0001-record-architecture-decisions.md 0002-openapi-authored-and-validated-not-generated.md]
  end

  it 'has both ADR files' do
    expect(expected.map { |name| File.exist?(File.join(adr_dir, name)) }).to eq([true, true])
  end

  it 'numbers every ADR file with four digits and a lowercase slug', :aggregate_failures do
    files = Dir.children(adr_dir)

    expect(files).to include(*expected)
    expect(files.grep_v(/\A\d{4}-[a-z0-9]+(-[a-z0-9]+)*\.md\z/)).to be_empty
  end

  %w[0001-record-architecture-decisions.md 0002-openapi-authored-and-validated-not-generated.md].each do |name|
    it "gives #{name} Status, Context, Decision and Consequences headings", :aggregate_failures do
      text = File.read(File.join(adr_dir, name))

      %w[Status Context Decision Consequences].each do |heading|
        expect(text).to match(/^\#{1,3}\s+#{heading}\b/), "#{name} has no #{heading} heading"
      end
    end
  end
end
