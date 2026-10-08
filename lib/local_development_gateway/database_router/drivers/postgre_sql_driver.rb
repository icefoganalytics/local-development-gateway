# frozen_string_literal: true

require "openssl"

require "local_development_gateway/database_router/wire"
require "local_development_gateway/database_router/drivers/postgre_sql_certificate"
require "local_development_gateway/database_router/postgre_sql/session"

module LocalDevelopmentGateway
  module DatabaseRouter::Drivers
    class PostgreSqlDriver
      NAME = "postgresql"
      LISTEN_PORT = 5432
      SSL_REQUEST = [8, 80_877_103].pack("NN").freeze
      CANCEL_REQUEST = [16, 80_877_102].pack("NN").freeze

      def initialize(
        certificate: PostgreSqlCertificate.new,
        cancellations: DatabaseRouter::PostgreSql::CancellationRoutes.new
      )
        @certificate = certificate
        @cancellations = cancellations
      end

      def name
        NAME
      end

      def listen_port
        LISTEN_PORT
      end

      def connect(client, routes:, connector:)
        deadline = DatabaseRouter::Wire.deadline
        request =
          DatabaseRouter::Wire.read_exactly(client, 8, deadline: deadline)
        if cancel_request?(request)
          cancel(client, connector, deadline)
          return
        end
        raise Error, "PostgreSQL SSL is required" unless request == SSL_REQUEST

        client.write("S")
        hostname = nil
        context =
          @certificate.context do |_socket, name|
            hostname = name&.downcase
            nil
          end
        tls = OpenSSL::SSL::SSLSocket.new(client, context)
        tls.sync_close = true
        DatabaseRouter::Wire.accept_tls(tls, deadline: deadline)

        startup = DatabaseRouter::Wire.read_exactly(tls, 8, deadline: deadline)
        if cancel_request?(startup)
          cancel(tls, connector, deadline)
          tls.close
          return
        end

        length, version = startup.unpack("NN")
        unless length >= 9 && (version >> 16) == 3
          raise Error, "Unsupported PostgreSQL startup request"
        end

        unless hostname
          raise Error, "PostgreSQL TLS ClientHello does not contain SNI"
        end

        selected = routes.call.find { |route| route.hostname == hostname }
        raise Error, "No PostgreSQL route for #{hostname}" unless selected

        target = connector.call(selected, deadline: deadline)
        target.write(startup)
        DatabaseRouter::Connection.new(
          source: tls,
          target: target,
          route: selected
        )
      rescue StandardError
        tls&.close
        target&.close
        raise
      end

      def forward(connection)
        session = DatabaseRouter::PostgreSql::Session.new(@cancellations)
        DatabaseRouter::Wire.proxy(
          connection.source,
          connection.target
        ) do |backend, client|
          session.forward_response(backend, client, connection.route)
        end
      end

      private

      def cancel_request?(header)
        return false unless header.byteslice(4, 4).unpack1("N") == 80_877_102
        unless header == CANCEL_REQUEST
          raise Error, "Invalid PostgreSQL cancellation length"
        end

        true
      end

      def cancel(client, connector, deadline)
        identity =
          DatabaseRouter::Wire.read_exactly(client, 8, deadline: deadline)
        destination = @cancellations.resolve(identity)
        return unless destination

        target = connector.call(destination.route, deadline: deadline)
        packet = [destination.backend_key.bytesize + 8, 80_877_102].pack("NN")
        target.write(packet + destination.backend_key)
        DatabaseRouter::Wire.read_until_eof(
          target,
          max_bytes: 0,
          deadline: deadline
        )
      ensure
        target&.close
      end
    end
  end
end
