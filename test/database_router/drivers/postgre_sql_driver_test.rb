# frozen_string_literal: true

require "openssl"
require "socket"
require "timeout"

require "minitest/autorun"

require "local_development_gateway"

class PostgreSqlDriverTest < Minitest::Test
  Router = LocalDevelopmentGateway::DatabaseRouter
  Route = Router::Route
  Driver = Router::Drivers::PostgreSqlDriver

  def test_cancels_an_active_tls_session_when_normal_session_capacity_is_full
    server = TCPServer.new("127.0.0.1", 0)
    selected = route("db.issue-a.wrap.localhost", server)
    routes = -> { [selected] }
    driver = Driver.new
    router =
      Router.new(
        routes: routes,
        drivers: [driver],
        servers: {
        },
        max_connections: 1
      )
    client, gateway = Socket.pair(:UNIX, :STREAM, 0)
    received = Queue.new
    cancelled = Queue.new
    parameters = "user\0app\0database\0development\0\0"
    startup = [parameters.bytesize + 8, 196_608].pack("NN") + parameters
    backend_key = [42, 1234].pack("NN")
    ready = "Z" + [5].pack("N") + "I"
    backend =
      Thread.new do
        connection = server.accept
        received << connection.read(startup.bytesize)
        connection.write("K" + [12].pack("N") + backend_key + ready)
        cancellation = server.accept
        cancelled << cancellation.read(16)
        cancellation.close
        connection.read
      ensure
        cancellation&.close
        connection&.close
      end
    router_thread = Thread.new { router.route(gateway, driver) }
    cancel_thread = nil
    cancel_client = nil
    cancel_gateway = nil

    client.write(Driver::SSL_REQUEST)
    assert_equal "S", client.read(1)
    context = OpenSSL::SSL::SSLContext.new
    context.verify_mode = OpenSSL::SSL::VERIFY_NONE
    tls = OpenSSL::SSL::SSLSocket.new(client, context)
    tls.hostname = selected.hostname
    tls.connect
    tls.write(startup)
    identity = tls.read(13).byteslice(5, 8)
    assert_equal ready, tls.read(ready.bytesize)
    assert_equal startup, received.pop

    cancel_client, cancel_gateway = Socket.pair(:UNIX, :STREAM, 0)
    cancel_thread = Thread.new { router.route(cancel_gateway, driver) }
    cancel_client.write(Driver::CANCEL_REQUEST + identity)

    assert_equal "", Timeout.timeout(5) { cancel_client.read }
    assert_equal Driver::CANCEL_REQUEST + backend_key, cancelled.pop
  ensure
    tls&.close
    [client, gateway, cancel_client, cancel_gateway, server].compact.each(
      &:close
    )
    [backend, router_thread, cancel_thread].compact.each(&:join)
  end

  def test_routes_plaintext_cancellation_without_hostname_or_route_discovery
    server = TCPServer.new("127.0.0.1", 0)
    selected = route("db.issue-b.wrap.localhost", server)
    cancellations = Router::PostgreSql::CancellationRoutes.new
    backend_key = [42].pack("N") + ("k" * 32)
    identity = cancellations.register(selected, backend_key)
    driver = Driver.new(cancellations: cancellations)
    discovery = -> { raise "Cancellation must not discover routes" }
    router = Router.new(routes: discovery, drivers: [driver], servers: {})
    client, gateway = Socket.pair(:UNIX, :STREAM, 0)
    received = Queue.new
    backend =
      Thread.new do
        connection = server.accept
        received << connection.read(44)
      ensure
        connection&.close
      end
    router_thread = Thread.new { router.route(gateway, driver) }

    client.write(Driver::CANCEL_REQUEST + identity)
    assert_equal "", client.read
    assert_equal [44, 80_877_102].pack("NN") + backend_key, received.pop
  ensure
    client&.close
    gateway&.close
    server&.close
    [backend, router_thread].compact.each(&:join)
  end

  def test_routes_encrypted_cancellation_using_the_virtual_identity
    server = TCPServer.new("127.0.0.1", 0)
    selected = route("db.issue-b.wrap.localhost", server)
    cancellations = Router::PostgreSql::CancellationRoutes.new
    backend_key = [42, 1234].pack("NN")
    identity = cancellations.register(selected, backend_key)
    driver = Driver.new(cancellations: cancellations)
    discovery = -> { raise "Cancellation must not discover routes" }
    router = Router.new(routes: discovery, drivers: [driver], servers: {})
    client, gateway = Socket.pair(:UNIX, :STREAM, 0)
    received = Queue.new
    backend =
      Thread.new do
        connection = server.accept
        received << connection.read(16)
      ensure
        connection&.close
      end
    router_thread = Thread.new { router.route(gateway, driver) }

    client.write(Driver::SSL_REQUEST)
    assert_equal "S", client.read(1)
    context = OpenSSL::SSL::SSLContext.new
    context.verify_mode = OpenSSL::SSL::VERIFY_NONE
    tls = OpenSSL::SSL::SSLSocket.new(client, context)
    tls.connect
    tls.write(Driver::CANCEL_REQUEST + identity)

    assert_equal "", tls.read
    assert_equal Driver::CANCEL_REQUEST + backend_key, received.pop
  ensure
    tls&.close
    client&.close
    gateway&.close
    server&.close
    [backend, router_thread].compact.each(&:join)
  end

  def test_unknown_cancellation_identity_never_opens_a_backend_connection
    server = TCPServer.new("127.0.0.1", 0)
    driver = Driver.new
    discovery = -> { raise "Cancellation must not discover routes" }
    router = Router.new(routes: discovery, drivers: [driver], servers: {})
    client, gateway = Socket.pair(:UNIX, :STREAM, 0)
    router_thread = Thread.new { router.route(gateway, driver) }

    client.write(Driver::CANCEL_REQUEST + [42, 1234].pack("NN"))
    assert_equal "", client.read
    assert_nil IO.select([server], nil, nil, 0)
  ensure
    client&.close
    gateway&.close
    server&.close
    router_thread&.join
  end

  def test_rejects_noncanonical_encrypted_cancellation_before_connecting_to_a_backend
    server = TCPServer.new("127.0.0.1", 0)
    selected = route("db.issue-a.wrap.localhost", server)
    driver = Driver.new
    discovery = -> { [selected] }
    router = Router.new(routes: discovery, drivers: [driver], servers: {})
    client, gateway = Socket.pair(:UNIX, :STREAM, 0)
    router_thread = nil
    tls = nil

    capture_io do
      router_thread = Thread.new { router.route(gateway, driver) }
      client.write(Driver::SSL_REQUEST)
      assert_equal "S", client.read(1)
      context = OpenSSL::SSL::SSLContext.new
      context.verify_mode = OpenSSL::SSL::VERIFY_NONE
      tls = OpenSSL::SSL::SSLSocket.new(client, context)
      tls.hostname = selected.hostname
      tls.connect
      tls.write([44, 80_877_102].pack("NN"))

      assert_equal "", Timeout.timeout(5) { tls.read }
      router_thread.join
    end
    assert_nil IO.select([server], nil, nil, 0)
  ensure
    tls&.close
    client&.close
    gateway&.close
    server&.close
    router_thread&.join
  end

  def test_rejects_nested_ssl_negotiation_before_backend_startup
    server = TCPServer.new("127.0.0.1", 0)
    selected = route("db.issue-a.wrap.localhost", server)
    driver = Driver.new
    discovery = -> { [selected] }
    router = Router.new(routes: discovery, drivers: [driver], servers: {})
    client, gateway = Socket.pair(:UNIX, :STREAM, 0)
    router_thread = nil
    tls = nil

    capture_io do
      router_thread = Thread.new { router.route(gateway, driver) }
      client.write(Driver::SSL_REQUEST)
      assert_equal "S", client.read(1)
      context = OpenSSL::SSL::SSLContext.new
      context.verify_mode = OpenSSL::SSL::VERIFY_NONE
      tls = OpenSSL::SSL::SSLSocket.new(client, context)
      tls.hostname = selected.hostname
      tls.connect
      tls.write(Driver::SSL_REQUEST)

      assert_equal "", Timeout.timeout(5) { tls.read }
      router_thread.join
    end
    assert_nil IO.select([server], nil, nil, 0)
  ensure
    tls&.close
    client&.close
    gateway&.close
    server&.close
    router_thread&.join
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
