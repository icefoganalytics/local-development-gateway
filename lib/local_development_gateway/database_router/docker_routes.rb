# frozen_string_literal: true

require "local_development_gateway/database_router/docker_api"

module LocalDevelopmentGateway
  class DatabaseRouter::DockerRoutes
    NETWORK_NAME = "local-gateway"
    HOSTNAME_LABEL = "local-gateway.tcp.hostname"
    PORT_LABEL = "local-gateway.tcp.port"
    DRIVER_LABEL = "local-gateway.tcp.driver"
    HOSTNAME_PATTERN = /\A(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+localhost\z/

    def initialize(client: DatabaseRouter::DockerApi.new)
      @client = client
    end

    def call
      routes =
        @client
          .get("/containers/json")
          .filter_map do |container|
            begin
              route(container)
            rescue Error => error
              warn error.message
              nil
            end
          end
      identities = routes.group_by { |route| [route.driver, route.hostname] }
      identities.each do |identity, matches|
        next if matches.length == 1

        warn "Duplicate labelled database hostname: #{identity.join(" ")}"
      end

      routes
        .reject do |route|
          identities.fetch([route.driver, route.hostname]).length > 1
        end
        .sort_by { |route| [route.driver, route.hostname] }
    end

    private

    def route(container)
      target_address =
        container.dig("NetworkSettings", "Networks", NETWORK_NAME, "IPAddress")
      return if target_address.nil? || target_address.empty?

      labels = container.fetch("Labels")
      driver = labels[DRIVER_LABEL]
      hostname = labels[HOSTNAME_LABEL]
      port = labels[PORT_LABEL]
      values = [driver, hostname, port]
      return if values.all?(&:nil?)
      raise Error, "Incomplete labelled database route" if values.any?(&:nil?)

      unless DatabaseRouter.drivers.any? { |candidate|
               candidate.name == driver
             }
        raise Error, "Unsupported database driver: #{driver}"
      end
      unless HOSTNAME_PATTERN.match?(hostname)
        raise Error, "Invalid labelled database hostname: #{hostname}"
      end

      port = Integer(port, 10)
      unless (1..65_535).cover?(port)
        raise Error, "Invalid labelled database port: #{port}"
      end

      DatabaseRouter::Route.new(
        driver: driver,
        hostname: hostname,
        port: port,
        target_address: target_address
      )
    rescue KeyError
      raise Error, "Incomplete labelled database route"
    rescue ArgumentError, TypeError
      raise Error, "Invalid labelled database port: #{port}"
    end
  end
end
