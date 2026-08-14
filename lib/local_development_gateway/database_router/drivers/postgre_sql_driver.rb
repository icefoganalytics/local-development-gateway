# frozen_string_literal: true

require "openssl"
require "local_development_gateway/database_router/wire"
require "local_development_gateway/database_router/drivers/postgre_sql_certificate"

module LocalDevelopmentGateway
  class DatabaseRouter::PostgreSqlDriver
    NAME = "postgresql"
    LISTEN_PORT = 5432
    SSL_REQUEST = [8, 80_877_103].pack("NN").freeze

    def initialize(certificate: DatabaseRouter::PostgreSqlCertificate.new)
      @certificate = certificate
    end

    def name
      NAME
    end

    def listen_port
      LISTEN_PORT
    end

    def connect(client, routes, connector:)
      deadline = DatabaseRouter::Wire.deadline
      request =
        DatabaseRouter::Wire.read_exactly(
          client,
          SSL_REQUEST.bytesize,
          deadline: deadline
        )
      raise Error, "PostgreSQL SSL is required" unless request == SSL_REQUEST
      if routes.empty?
        raise Error, "No labelled postgresql routes are available"
      end

      client.write("S")
      hostname = nil
      context =
        @certificate.context do |_socket, name|
          hostname = name&.downcase
          nil
        end
      tls = OpenSSL::SSL::SSLSocket.new(client, context)
      tls.sync_close = false
      DatabaseRouter::Wire.accept_tls(tls, deadline: deadline)
      unless hostname
        raise Error, "PostgreSQL TLS ClientHello does not contain SNI"
      end

      selected = routes.find { |route| route.hostname == hostname }
      raise Error, "No PostgreSQL route for #{hostname}" unless selected

      [tls, connector.call(selected)]
    end
  end
end
