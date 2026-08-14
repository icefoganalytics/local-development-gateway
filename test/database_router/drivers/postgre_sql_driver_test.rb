# frozen_string_literal: true

require "minitest/autorun"
require "openssl"
require "socket"
require "local_development_gateway"

class PostgreSqlDriverTest < Minitest::Test
  Router = LocalDevelopmentGateway::DatabaseRouter
  Route = Router::Route

  def test_terminates_tls_and_proxies_plaintext_to_the_labelled_backend
    server = TCPServer.new("127.0.0.1", 0)
    route = route("db.issue-a.wrap.localhost", server)
    routes = -> { [route] }
    driver = Router::PostgreSqlDriver.new
    router = Router.new(routes: routes, drivers: [driver], servers: {})
    client, gateway = Socket.pair(:UNIX, :STREAM, 0)
    received = Queue.new
    backend =
      Thread.new do
        connection = server.accept
        received << connection.read(7)
        connection.write("ready")
        connection.close_write
      ensure
        connection&.close
      end
    router_thread = Thread.new { router.route(gateway, driver) }

    client.write(Router::PostgreSqlDriver::SSL_REQUEST)
    assert_equal "S", client.read(1)
    context = OpenSSL::SSL::SSLContext.new
    context.verify_mode = OpenSSL::SSL::VERIFY_NONE
    tls = OpenSSL::SSL::SSLSocket.new(client, context)
    tls.hostname = route.hostname
    tls.connect
    tls.write("startup")

    assert_equal "ready", tls.read(5)
    assert_equal "startup", received.pop
  ensure
    tls&.close
    client&.close
    gateway&.close
    server&.close
    [backend, router_thread].compact.each(&:join)
  end

  private

  def route(hostname, server)
    Route.new(
      driver: "postgresql",
      hostname: hostname,
      port: server.local_address.ip_port,
      target_address: "127.0.0.1"
    )
  end
end
