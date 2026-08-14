# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "local_development_gateway"

class DatabaseRouterTest < Minitest::Test
  Router = LocalDevelopmentGateway::DatabaseRouter

  def test_builds_default_dependencies_without_starting_listeners
    assert_instance_of Router, Router.new(servers: {})
  end

  def test_closed_health_checks_do_not_log_missing_routes
    [Router::SqlServerDriver.new, Router::PostgreSqlDriver.new].each do |driver|
      client, gateway = Socket.pair(:UNIX, :STREAM, 0)
      router = Router.new(routes: -> { [] }, drivers: [driver], servers: {})
      client.close

      _stdout, stderr = capture_io { router.route(gateway, driver) }

      assert_empty stderr
    ensure
      client&.close
      gateway&.close
    end
  end
end
