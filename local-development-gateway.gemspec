# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "local_development_gateway/version"

Gem::Specification.new do |spec|
  spec.name = "local-development-gateway"
  spec.version = LocalDevelopmentGateway::VERSION
  spec.summary =
    "Shared loopback gateway lifecycle for local Docker development"
  spec.description =
    "Ruby API and CLI for starting, monitoring, and conditionally stopping the shared Docker gateway."
  spec.authors = ["Marlen Brunner"]
  spec.email = ["marlen@icefoganalytics.com"]
  spec.homepage = "https://github.com/icefoganalytics/local-development-gateway"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files =
    Dir[
      "README.md",
      "docker-compose.yml",
      "config/traefik.yml",
      "bin/local-development-gateway",
      "lib/**/*.rb"
    ]
  spec.bindir = "bin"
  spec.executables = ["local-development-gateway"]
  spec.require_paths = ["lib"]
  spec.metadata = {
    "bug_tracker_uri" =>
      "https://github.com/icefoganalytics/local-development-gateway/issues",
    "source_code_uri" =>
      "https://github.com/icefoganalytics/local-development-gateway"
  }
end
