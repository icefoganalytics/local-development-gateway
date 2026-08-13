# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require_relative "../lib/local_development_gateway"

class TdsRouterTest < Minitest::Test
  Route = LocalDevelopmentGateway::TdsRouter::Route

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

  def test_discovers_labelled_routes_on_the_gateway_network
    containers = [
      container("db.issue-b.wrap.localhost", "1433", "172.20.0.3"),
      container("db.issue-a.wrap.localhost", "1433", "172.20.0.2"),
      { "Labels" => {}, "NetworkSettings" => { "Networks" => {} } }
    ]

    routes = docker_routes(containers).call

    assert_equal(
      [
        ["db.issue-a.wrap.localhost", 1433, "172.20.0.2"],
        ["db.issue-b.wrap.localhost", 1433, "172.20.0.3"]
      ],
      routes.map { |route| [route.hostname, route.port, route.target_address] }
    )
  end

  def test_rejects_duplicate_hostnames
    containers = [
      container("db.issue-a.wrap.localhost", "1433", "172.20.0.2"),
      container("db.issue-a.wrap.localhost", "1433", "172.20.0.3")
    ]

    error =
      assert_raises(LocalDevelopmentGateway::Error) do
        docker_routes(containers).call
      end

    assert_equal "Duplicate labelled TDS hostname", error.message
  end

  def test_rejects_invalid_target_ports
    error =
      assert_raises(LocalDevelopmentGateway::Error) do
        docker_routes(
          [container("db.issue-a.wrap.localhost", "not-a-port", "172.20.0.2")]
        ).call
      end

    assert_equal "Invalid labelled TDS port: not-a-port", error.message
  end

  def test_reads_server_name_from_a_wrapped_tls_client_hello
    hello = tls_client_hello("db.issue-b.wrap.localhost")

    assert_equal(
      "db.issue-b.wrap.localhost",
      LocalDevelopmentGateway::TdsRouter::TlsClientHello.server_name(hello)
    )
  end

  def test_switches_the_tds_connection_to_the_sni_labelled_backend
    first_server = TCPServer.new("127.0.0.1", 0)
    second_server = TCPServer.new("127.0.0.1", 0)
    routes = -> do
      [
        route("db.issue-a.wrap.localhost", first_server),
        route("db.issue-b.wrap.localhost", second_server)
      ]
    end
    router = LocalDevelopmentGateway::TdsRouter.new(routes: routes, server: nil)
    client, gateway = Socket.pair(:UNIX, :STREAM, 0)
    received = Queue.new

    first_thread = fake_backend(first_server, "first-prelogin", received)
    second_thread =
      fake_backend(
        second_server,
        "second-prelogin",
        received,
        reply: "selected-b"
      )
    router_thread = Thread.new { router.route(gateway) }

    client.write(tds_message("client-prelogin"))
    assert_equal "first-prelogin", read_tds_message(client)
    client.write(tds_message(tls_client_hello("db.issue-b.wrap.localhost")))
    assert_equal "selected-b", client.read

    assert_equal "client-prelogin", received.pop
    assert_equal "client-prelogin", received.pop
    assert_equal "db.issue-b.wrap.localhost", received.pop
  ensure
    client&.close
    gateway&.close
    first_server&.close
    second_server&.close
    [first_thread, second_thread, router_thread].compact.each(&:join)
  end

  def test_skips_an_unreachable_backend_during_prelogin
    unavailable = TCPServer.new("127.0.0.1", 0)
    unavailable_port = unavailable.local_address.ip_port
    unavailable.close
    server = TCPServer.new("127.0.0.1", 0)
    routes = -> do
      [
        Route.new(
          hostname: "db.issue-a.wrap.localhost",
          port: unavailable_port,
          target_address: "127.0.0.1"
        ),
        route("db.issue-b.wrap.localhost", server)
      ]
    end
    router = LocalDevelopmentGateway::TdsRouter.new(routes: routes, server: nil)
    client, gateway = Socket.pair(:UNIX, :STREAM, 0)
    received = Queue.new
    backend =
      fake_backend(server, "available-prelogin", received, reply: "selected-b")
    router_thread = Thread.new { router.route(gateway) }

    client.write(tds_message("client-prelogin"))
    assert_equal "available-prelogin", read_tds_message(client)
    client.write(tds_message(tls_client_hello("db.issue-b.wrap.localhost")))
    assert_equal "selected-b", client.read
  ensure
    client&.close
    gateway&.close
    server&.close
    [backend, router_thread].compact.each(&:join)
  end

  private

  def container(hostname, port, address)
    {
      "Labels" => {
        "local-gateway.tcp.hostname" => hostname,
        "local-gateway.tcp.port" => port
      },
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
    LocalDevelopmentGateway::TdsRouter::DockerRoutes.new(
      client: FakeDockerApi.new(containers)
    )
  end

  def route(hostname, server)
    Route.new(
      hostname: hostname,
      port: server.local_address.ip_port,
      target_address: "127.0.0.1"
    )
  end

  def fake_backend(server, prelogin_response, received, reply: nil)
    Thread.new do
      connection = server.accept
      received << read_tds_message(connection)
      connection.write(tds_message(prelogin_response))
      if reply
        hello = read_tds_message(connection)
        received << LocalDevelopmentGateway::TdsRouter::TlsClientHello.server_name(
          hello
        )
        connection.write(reply)
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
