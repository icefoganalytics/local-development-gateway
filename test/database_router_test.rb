# frozen_string_literal: true

require "socket"

require "minitest/autorun"

require "local_development_gateway"

class DatabaseRouterTest < Minitest::Test
  Router = LocalDevelopmentGateway::DatabaseRouter

  def test_closed_health_checks_do_not_log_missing_routes
    [
      Router::Drivers::SqlServerDriver.new,
      Router::Drivers::PostgreSqlDriver.new
    ].each do |driver|
      client, gateway = Socket.pair(:UNIX, :STREAM, 0)
      discovery = -> { raise "Closed probes must not discover Docker routes" }
      router = Router.new(routes: discovery, drivers: [driver], servers: {})
      client.close

      _stdout, stderr = capture_io { router.route(gateway, driver) }

      assert_empty stderr
    ensure
      client&.close
      gateway&.close
    end
  end
end
