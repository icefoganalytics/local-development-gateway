# frozen_string_literal: true

require "openssl"
require "socket"

module LocalDevelopmentGateway
  class DatabaseRouter
    CONNECT_TIMEOUT = 3
    MAX_CONNECTIONS = 128

    def self.run
      new.run
    end

    def self.drivers
      @drivers ||= [SqlServerDriver.new, PostgreSqlDriver.new].freeze
    end

    def initialize(
      routes: DockerRoutes.new,
      drivers: self.class.drivers,
      servers: nil
    )
      @routes = routes
      @drivers = drivers
      @servers =
        servers ||
          drivers.to_h do |driver|
            [driver.name, TCPServer.new("0.0.0.0", driver.listen_port)]
          end
    end

    def run
      slots = SizedQueue.new(MAX_CONNECTIONS)
      MAX_CONNECTIONS.times { slots << true }
      @drivers
        .map do |driver|
          Thread.new do
            server = @servers.fetch(driver.name)
            loop do
              client = server.accept
              slots.pop
              Thread.new(client) do |connection|
                route(connection, driver)
              ensure
                slots << true
              end
            end
          end
        end
        .each(&:join)
    end

    def route(client, driver)
      routes = @routes.call.select { |route| route.driver == driver.name }

      source, target =
        driver.connect(client, routes, connector: method(:connect))
      proxy(source, target)
    rescue EOFError
      nil
    rescue Error => error
      warn error.message
    rescue StandardError => error
      warn error.full_message
    ensure
      source&.close unless source.equal?(client)
      client&.close
      target&.close
    end

    private

    def connect(route)
      Socket.tcp(
        route.target_address,
        route.port,
        connect_timeout: CONNECT_TIMEOUT
      )
    end

    def proxy(client, target)
      [[client, target], [target, client]].map do |source, destination|
          Thread.new do
            IO.copy_stream(source, destination)
          rescue IOError, OpenSSL::SSL::SSLError, SystemCallError
            nil
          ensure
            if destination.respond_to?(:close_write) && !destination.closed?
              destination.close_write
            end
          end
        end
        .each(&:join)
    end
  end
end

require_relative "database_router/route"
require_relative "database_router/wire"
require_relative "database_router/docker_api"
require_relative "database_router/docker_routes"
require_relative "database_router/tds_packet"
require_relative "database_router/tds_message"
require_relative "database_router/tls_byte_reader"
require_relative "database_router/tls_client_hello"
require_relative "database_router/sql_server_driver"
require_relative "database_router/postgre_sql_certificate"
require_relative "database_router/postgre_sql_driver"
