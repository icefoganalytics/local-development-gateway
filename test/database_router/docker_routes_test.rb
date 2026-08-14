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
