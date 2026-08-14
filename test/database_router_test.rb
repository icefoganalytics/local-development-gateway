# frozen_string_literal: true

require "minitest/autorun"
require "openssl"
require "socket"
require_relative "../lib/local_development_gateway"

class DatabaseRouterTest < Minitest::Test
  Router = LocalDevelopmentGateway::DatabaseRouter
  Route = Router::Route

  class FakeDockerApi
    def initialize(containers)
      @containers = containers
    end

    def get(path)
      unless path == "/containers/json"
        raise "unexpected Docker API path: #{path}"
      end

      @containers
    end
  end

  def test_builds_default_dependencies_without_starting_listeners
    assert_instance_of Router, Router.new(servers: {})
  end

  def test_discovers_routes_for_each_database_driver
    containers = [
      container("postgresql", "db.pg.wrap.localhost", "5432", "172.20.0.3"),
      container("sql_server", "db.sql.wrap.localhost", "1433", "172.20.0.2"),
      { "Labels" => {}, "NetworkSettings" => { "Networks" => {} } }
    ]

    routes = docker_routes(containers).call

    assert_equal(
      [
        ["postgresql", "db.pg.wrap.localhost", 5432, "172.20.0.3"],
        ["sql_server", "db.sql.wrap.localhost", 1433, "172.20.0.2"]
      ],
      routes.map { |route| route.to_h.values }
    )
  end

  def test_rejects_incomplete_routes
    error =
      assert_raises(LocalDevelopmentGateway::Error) do
        docker_routes(
          [container(nil, "db.issue-a.wrap.localhost", "1433", "172.20.0.2")]
        ).call
      end

    assert_equal "Incomplete labelled database route", error.message
  end

  def test_rejects_unsupported_database_drivers
    error =
      assert_raises(LocalDevelopmentGateway::Error) do
        docker_routes(
          [
            container(
              "mysql",
              "db.issue-a.wrap.localhost",
              "3306",
              "172.20.0.2"
            )
          ]
        ).call
      end

    assert_equal "Unsupported database driver: mysql", error.message
  end

  def test_rejects_duplicate_driver_hostnames
    containers = [
      container(
        "sql_server",
        "db.issue-a.wrap.localhost",
        "1433",
        "172.20.0.2"
      ),
      container("sql_server", "db.issue-a.wrap.localhost", "1433", "172.20.0.3")
    ]

    error =
      assert_raises(LocalDevelopmentGateway::Error) do
        docker_routes(containers).call
      end

    assert_equal "Duplicate labelled database hostname", error.message
  end

  def test_reads_a_fragmented_tls_client_hello
    hello = tls_client_hello("db.issue-b.wrap.localhost")
    parser = Router::TlsClientHello.new

    refute parser.append(hello.byteslice(0, 10))
    assert_equal "db.issue-b.wrap.localhost",
                 parser.append(hello.byteslice(10..))
  end

  def test_rejects_oversized_tls_client_hello
    parser = Router::TlsClientHello.new

    error =
      assert_raises(LocalDevelopmentGateway::Error) do
        parser.append("x" * (Router::TlsClientHello::MAX_BYTES + 1))
      end

    assert_equal "TLS ClientHello is too large", error.message
  end

  def test_database_handshake_reads_have_one_deadline
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)

    error =
      assert_raises(LocalDevelopmentGateway::Error) do
        Router::Wire.read_exactly(reader, 1, deadline: 0)
      end

    assert_equal "Database handshake timed out", error.message
  ensure
    reader&.close
    writer&.close
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

  def test_sql_server_switches_to_the_sni_labelled_backend
    first_server = TCPServer.new("127.0.0.1", 0)
    second_server = TCPServer.new("127.0.0.1", 0)
    routes = -> do
      [
        route("sql_server", "db.issue-a.wrap.localhost", first_server),
        route("sql_server", "db.issue-b.wrap.localhost", second_server)
      ]
    end
    driver = Router::SqlServerDriver.new
    router = Router.new(routes: routes, drivers: [driver], servers: {})
    client, gateway = Socket.pair(:UNIX, :STREAM, 0)
    received = Queue.new

    first_thread = fake_sql_server(first_server, "first-prelogin", received)
    second_thread =
      fake_sql_server(
        second_server,
        "second-prelogin",
        received,
        selected: true
      )
    router_thread = Thread.new { router.route(gateway, driver) }

    client.write(tds_message("client-prelogin"))
    assert_equal "first-prelogin", read_tds_message(client)
    hello = tls_client_hello("db.issue-b.wrap.localhost")
    client.write(tds_message(hello.byteslice(0, 10)))
    client.write(tds_message(hello.byteslice(10..)))
    assert_equal "selected-b", client.read

    assert_equal %w[client-prelogin client-prelogin],
                 2.times.map { received.pop }
    assert_equal "db.issue-b.wrap.localhost", received.pop
  ensure
    client&.close
    gateway&.close
    first_server&.close
    second_server&.close
    [first_thread, second_thread, router_thread].compact.each(&:join)
  end

  def test_postgresql_terminates_tls_and_proxies_plaintext_to_the_labelled_backend
    server = TCPServer.new("127.0.0.1", 0)
    route = route("postgresql", "db.issue-a.wrap.localhost", server)
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

  def container(driver, hostname, port, address)
    labels = {
      "local-gateway.tcp.hostname" => hostname,
      "local-gateway.tcp.port" => port
    }
    labels["local-gateway.tcp.driver"] = driver if driver
    {
      "Labels" => labels,
      "NetworkSettings" => {
        "Networks" => {
          "local-gateway" => {
            "IPAddress" => address
          }
        }
      }
    }
  end

  def docker_routes(containers)
    Router::DockerRoutes.new(client: FakeDockerApi.new(containers))
  end

  def route(driver, hostname, server)
    Route.new(
      driver: driver,
      hostname: hostname,
      port: server.local_address.ip_port,
      target_address: "127.0.0.1"
    )
  end

  def fake_sql_server(server, prelogin_response, received, selected: false)
    Thread.new do
      connection = server.accept
      received << read_tds_message(connection)
      connection.write(tds_message(prelogin_response))
      if selected
        parser = Router::TlsClientHello.new
        hostname = nil
        hostname ||= parser.append(read_tds_message(connection)) until hostname
        received << hostname
        connection.write("selected-b")
      else
        connection.read
      end
    ensure
      connection&.close
    end
  end

  def tds_message(payload)
    [18, 1, payload.bytesize + 8, 0, 1, 0].pack("CCnnCC") + payload
  end

  def read_tds_message(io)
    header = io.read(8)
    raise EOFError unless header&.bytesize == 8

    io.read(header.byteslice(2, 2).unpack1("n") - 8)
  end

  def tls_client_hello(hostname)
    server_name =
      [hostname.bytesize + 3, 0, hostname.bytesize].pack("nCn") + hostname
    extension = [0, server_name.bytesize].pack("nn") + server_name
    body =
      [0x0303].pack("n") + ("\0" * 32) + [0, 2, 0x1301, 1, 0].pack("CnnCC") +
        [extension.bytesize].pack("n") + extension
    handshake = [1].pack("C") + [body.bytesize].pack("N").byteslice(1, 3) + body
    [22, 0x0301, handshake.bytesize].pack("Cnn") + handshake
  end
end
