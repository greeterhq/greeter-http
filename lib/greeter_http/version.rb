# frozen_string_literal: true

module GreeterHttp
  # The service version. The release job asserts this matches the pushed `v*`
  # tag (see .github/workflows/ci.yml), so bump it in the same commit as a
  # release tag. Surfaced in the startup banner for deployment observability.
  VERSION = '0.5.15'
end
