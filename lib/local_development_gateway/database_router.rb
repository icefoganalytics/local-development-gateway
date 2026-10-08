# frozen_string_literal: true

require "openssl"
require "socket"

module LocalDevelopmentGateway
  class DatabaseRouter
    CONNECT_TIMEOUT = 3
    MAX_CONNECTIONS = 128
    MAX_HANDSHAKES = 128
    Route = Data.define(:driver, :hostname, :port, :target_address)
    Connection = Data.define(:source, :target, :route)

    def self.run
      new.run
    end

    def self.drivers
      @drivers ||= [
        Drivers::SqlServerDriver.new,
        Drivers::PostgreSqlDriver.new
      ].freeze
    end

    def initialize(
      routes: DockerRoutes.new,
      drivers: self.class.drivers,
      servers: nil,
      max_connections: MAX_CONNECTIONS
    )
      @routes = routes
      @drivers = drivers
      @session_slots = SizedQueue.new(max_connections)
      max_connections.times { @session_slots << true }
      @servers =
        servers ||
          drivers.to_h do |driver|
            [driver.name, TCPServer.new("0.0.0.0", driver.listen_port)]
          end
    end

    def run
      slots = SizedQueue.new(MAX_HANDSHAKES)
      MAX_HANDSHAKES.times { slots << true }
      @drivers
        .map do |driver|
          Thread.new do
            server = @servers.fetch(driver.name)
            loop do
              client = server.accept
              slots.pop
              Thread.new(client) do |connection|
                route(connection, driver, handshake_slots: slots)
              end
            end
          end
        end
        .each(&:join)
    end

    def route(client, driver, handshake_slots: nil)
      routes = -> do
        @routes.call.select { |route| route.driver == driver.name }
      end
      connection =
        driver.connect(client, routes: routes, connector: method(:connect))
      handshake_slots&.push(true)
      handshake_slots = nil
      return unless connection

      session_slot = @session_slots.pop(true)
      driver.forward(connection)
    rescue EOFError
      nil
    rescue ThreadError
      warn "Database session limit reached"
    rescue Error => error
      warn error.message
    rescue StandardError => error
      warn error.full_message
    ensure
      handshake_slots&.push(true)
      @session_slots << true if session_slot
      connection&.source&.close
      client&.close
      connection&.target&.close
    end

    private

    def connect(route, deadline:)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Error, "Database handshake timed out" unless remaining.positive?

      Socket.tcp(
        route.target_address,
        route.port,
        connect_timeout: [CONNECT_TIMEOUT, remaining].min
      )
    end
  end
end

require "local_development_gateway/database_router/docker_routes"
require "local_development_gateway/database_router/drivers/sql_server_driver"
require "local_development_gateway/database_router/drivers/postgre_sql_driver"
