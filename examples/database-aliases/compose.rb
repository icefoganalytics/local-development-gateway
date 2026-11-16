#!/usr/bin/env ruby

require "local_development_gateway"
require "open3"
require "json"

delimiter = ARGV.index("--")
unless delimiter && delimiter < ARGV.length - 1
  abort "Usage: ruby compose.rb [native Compose global options] -- COMMAND [args]"
end

global_options = ARGV.take(delimiter)
command = ARGV.drop(delimiter + 1)
compose = ["docker", "compose", *global_options]
discovery_environment = {
  "DB_HOST" => "alias-discovery-only",
  "DB_TRAV_COM_HOST" => "alias-discovery-only"
}

# Render only: never create services with discovery placeholders. Compose owns
# project-name precedence, file selection, interpolation, and directory defaults.
configuration, diagnostics, status =
  Open3.capture3(discovery_environment, *compose, "config", "--format", "json")
$stderr.write(diagnostics)
exit(status.exitstatus || 1) unless status.success?

project_name = JSON.parse(configuration).fetch("name")
host_environment = {
  "DB_HOST" =>
    LocalDevelopmentGateway.database_alias(
      project_name: project_name,
      service_name: "db"
    ),
  "DB_TRAV_COM_HOST" =>
    LocalDevelopmentGateway.database_alias(
      project_name: project_name,
      service_name: "db_trav_com"
    )
}

exec(host_environment, *compose, *command)
