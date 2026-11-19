# frozen_string_literal: true

# Steps for the fixture features run by
# spec/tooling/cucumber_repo_trace_spec.rb. The failure message carries no
# guest name; the writer must not read it anyway.
Given('a step for {string} that passes') { |_name| nil }

Given('a step for {string} that fails') { |_name| raise 'fixture failure' }

Given('a step for {string} that is pending') { |_name| pending }

Given('a step for {string} that is skipped') { |_name| skip_this_scenario }
