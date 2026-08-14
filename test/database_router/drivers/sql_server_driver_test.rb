# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "local_development_gateway"

class SqlServerDriverTest < Minitest::Test
  Router = LocalDevelopmentGateway::DatabaseRouter
  Route = Router::Route
  Driver = Router::Drivers::SqlServerDriver

  def test_switches_to_the_sni_labelled_backend
    first_server = TCPServer.new("127.0.0.1", 0)
    second_server = TCPServer.new("127.0.0.1", 0)
    routes = -> do
      [
        route("db.issue-a.wrap.localhost", first_server),
        route("db.issue-b.wrap.localhost", second_server)
      ]
    end
    driver = Driver.new
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

  private

  def route(hostname, server)
    Route.new(
      driver: "sql_server",
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
        parser = Router::Tds::TlsClientHello.new
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
