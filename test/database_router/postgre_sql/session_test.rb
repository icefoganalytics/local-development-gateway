# frozen_string_literal: true

require "socket"
require "timeout"

require "minitest/autorun"

require "local_development_gateway"

class PostgreSqlSessionTest < Minitest::Test
  Router = LocalDevelopmentGateway::DatabaseRouter

  def test_rewrites_backend_key_and_removes_its_route_when_the_session_ends
    route =
      Router::Route.new(
        driver: "postgresql",
        hostname: "db.session.localhost",
        port: 5432,
        target_address: "172.20.0.2"
      )
    cancellations = Router::PostgreSql::CancellationRoutes.new
    session = Router::PostgreSql::Session.new(cancellations)
    backend, gateway = Socket.pair(:UNIX, :STREAM, 0)
    client, downstream = Socket.pair(:UNIX, :STREAM, 0)
    backend_key = [42].pack("N") + ("k" * 256)
    authentication = "R" + [8, 0].pack("NN")
    ready = "Z" + [5].pack("N") + "I"
    thread = Thread.new { session.forward_response(gateway, downstream, route) }

    backend.write(authentication + "K" + [264].pack("N") + backend_key + ready)
    assert_equal authentication, client.read(authentication.bytesize)
    public_key_message = client.read(13)
    identity = public_key_message.byteslice(5, 8)
    assert_equal "K" + [12].pack("N"), public_key_message.byteslice(0, 5)
    assert_equal route, cancellations.resolve(identity).route
    assert_equal backend_key, cancellations.resolve(identity).backend_key
    assert_equal ready, client.read(ready.bytesize)

    backend.close_write
    Timeout.timeout(5) { thread.join }
    assert_nil cancellations.resolve(identity)
  ensure
    [backend, gateway, client, downstream].compact.each(&:close)
    thread&.join
  end

  def test_truncated_backend_key_is_not_registered_or_forwarded
    route =
      Router::Route.new(
        driver: "postgresql",
        hostname: "db.session.localhost",
        port: 5432,
        target_address: "172.20.0.2"
      )
    cancellations = Router::PostgreSql::CancellationRoutes.new
    session = Router::PostgreSql::Session.new(cancellations)
    backend, gateway = Socket.pair(:UNIX, :STREAM, 0)
    client, downstream = Socket.pair(:UNIX, :STREAM, 0)
    backend.write("K" + [12].pack("N") + [42].pack("N"))
    backend.close_write

    assert_raises(EOFError) do
      session.forward_response(gateway, downstream, route)
    end
    assert_nil IO.select([client], nil, nil, 0)
  ensure
    [backend, gateway, client, downstream].compact.each(&:close)
  end
end
