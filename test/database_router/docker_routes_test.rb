# frozen_string_literal: true

require "minitest/autorun"

require "local_development_gateway"

class DockerRoutesTest < Minitest::Test
  Router = LocalDevelopmentGateway::DatabaseRouter

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

  def test_ignores_invalid_metadata_for_containers_outside_the_gateway_network
    containers = [
      container("unsupported", "not a hostname", "invalid", nil),
      container("postgresql", "db.pg.wrap.localhost", "5432", "172.20.0.3")
    ]

    routes = docker_routes(containers).call

    assert_equal(
      [["postgresql", "db.pg.wrap.localhost", 5432, "172.20.0.3"]],
      routes.map { |route| route.to_h.values }
    )
  end

  def test_quarantines_an_invalid_route_without_dropping_valid_routes
    containers = [
      container("postgresql", "invalid hostname", "5432", "172.20.0.4"),
      container("sql_server", "db.sql.wrap.localhost", "1433", "172.20.0.2")
    ]

    routes = docker_routes(containers).call

    assert_equal(
      [["sql_server", "db.sql.wrap.localhost", 1433, "172.20.0.2"]],
      routes.map { |route| route.to_h.values }
    )
  end

  def test_quarantines_all_routes_for_duplicate_identity_only
    containers = [
      container(
        "postgresql",
        "db.duplicate.wrap.localhost",
        "5432",
        "172.20.0.2"
      ),
      container(
        "postgresql",
        "db.duplicate.wrap.localhost",
        "5432",
        "172.20.0.3"
      ),
      container("postgresql", "db.other.wrap.localhost", "5432", "172.20.0.4"),
      container(
        "sql_server",
        "db.duplicate.wrap.localhost",
        "1433",
        "172.20.0.5"
      )
    ]

    capture_io do
      routes = docker_routes(containers).call
      assert_equal(
        [
          ["postgresql", "db.other.wrap.localhost", 5432, "172.20.0.4"],
          ["sql_server", "db.duplicate.wrap.localhost", 1433, "172.20.0.5"]
        ],
        routes.map { |route| route.to_h.values }
      )
    end
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
end
