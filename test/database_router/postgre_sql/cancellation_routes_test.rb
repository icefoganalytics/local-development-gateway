# frozen_string_literal: true

require "minitest/autorun"

require "local_development_gateway"

class PostgreSqlCancellationRoutesTest < Minitest::Test
  Router = LocalDevelopmentGateway::DatabaseRouter
  CancellationRoutes = Router::PostgreSql::CancellationRoutes

  def test_backend_key_collisions_remain_isolated_by_virtual_identity
    first_route =
      Router::Route.new(
        driver: "postgresql",
        hostname: "db.first.localhost",
        port: 5432,
        target_address: "172.20.0.2"
      )
    second_route =
      Router::Route.new(
        driver: "postgresql",
        hostname: "db.second.localhost",
        port: 5432,
        target_address: "172.20.0.3"
      )
    backend_key = [42, 1234].pack("NN")
    identities = [
      [0x80000001, 1234].pack("NN"),
      [1, 1234].pack("NN"),
      [2, 1234].pack("NN")
    ]
    cancellations = CancellationRoutes.new

    SecureRandom.stub(:random_bytes, ->(_length) { identities.shift.dup }) do
      first_identity = cancellations.register(first_route, backend_key)
      second_identity = cancellations.register(second_route, backend_key)

      assert_operator first_identity.unpack1("l>"), :>, 0

      assert_equal first_route, cancellations.resolve(first_identity).route
      assert_equal second_route, cancellations.resolve(second_identity).route
      assert_equal backend_key,
                   cancellations.resolve(second_identity).backend_key
    end
  end

  def test_removing_a_session_does_not_remove_another_session_with_the_same_backend_key
    route =
      Router::Route.new(
        driver: "postgresql",
        hostname: "db.first.localhost",
        port: 5432,
        target_address: "172.20.0.2"
      )
    backend_key = [42, 1234].pack("NN")
    cancellations = CancellationRoutes.new
    first_identity = cancellations.register(route, backend_key)
    second_identity = cancellations.register(route, backend_key)

    cancellations.remove(first_identity)

    assert_nil cancellations.resolve(first_identity)
    assert_equal backend_key, cancellations.resolve(second_identity).backend_key
  end

  def test_a_zero_random_pid_is_not_exposed_to_clients
    route =
      Router::Route.new(
        driver: "postgresql",
        hostname: "db.first.localhost",
        port: 5432,
        target_address: "172.20.0.2"
      )
    backend_key = [42, 1234].pack("NN")
    cancellations = CancellationRoutes.new
    identity = nil

    SecureRandom.stub(:random_bytes, ->(_length) { [0, 1234].pack("NN") }) do
      identity = cancellations.register(route, backend_key)
    end

    assert_operator identity.unpack1("l>"), :>, 0
    assert_equal backend_key, cancellations.resolve(identity).backend_key
  end
end
