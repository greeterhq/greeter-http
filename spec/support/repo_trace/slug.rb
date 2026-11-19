# frozen_string_literal: true

module RepoTrace
  # The shared greeterHQ slug rule: lowercase, each run of characters other
  # than a-z and 0-9 becomes one '-', and '-' is trimmed from both ends.
  module Slug
    module_function

    def call(text)
      text.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
    end
  end
end
