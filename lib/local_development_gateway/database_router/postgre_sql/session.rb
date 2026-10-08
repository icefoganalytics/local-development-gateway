# frozen_string_literal: true

require "local_development_gateway/database_router/postgre_sql/cancellation_routes"

module LocalDevelopmentGateway
  class DatabaseRouter::PostgreSql::Session
    MAX_BACKEND_KEY_BYTES = 260

    def initialize(cancellations)
      @cancellations = cancellations
    end

    def forward_response(backend, client, route)
      identity = nil
      loop do
        header = backend.read(5)
        raise EOFError unless header&.bytesize == 5

        payload_length = header.byteslice(1, 4).unpack1("N") - 4
        if payload_length.negative?
          raise Error, "Invalid PostgreSQL message length"
        end

        if header.getbyte(0) == "K".ord
          unless (8..MAX_BACKEND_KEY_BYTES).cover?(payload_length)
            raise Error, "Invalid PostgreSQL backend key length"
          end

          backend_key = backend.read(payload_length)
          raise EOFError unless backend_key&.bytesize == payload_length

          identity = @cancellations.register(route, backend_key)
          client.write("K" + [12].pack("N") + identity)
          IO.copy_stream(backend, client)
          return
        end

        client.write(header)
        copied = IO.copy_stream(backend, client, payload_length)
        raise EOFError unless copied == payload_length
      end
    ensure
      @cancellations.remove(identity) if identity
    end
  end
end
