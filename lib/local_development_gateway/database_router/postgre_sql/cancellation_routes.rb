# frozen_string_literal: true

require "securerandom"

module LocalDevelopmentGateway
  module DatabaseRouter::PostgreSql
    class CancellationRoutes
      Destination = Data.define(:route, :backend_key)

      def initialize
        @destinations = {}
        @mutex = Mutex.new
      end

      def register(route, backend_key)
        @mutex.synchronize do
          identity = new_identity
          identity = new_identity while @destinations.key?(identity)

          identity.freeze
          @destinations[identity] = Destination.new(
            route: route,
            backend_key: backend_key.dup.freeze
          )
          identity
        end
      end

      def resolve(identity)
        @mutex.synchronize { @destinations[identity] }
      end

      def remove(identity)
        @mutex.synchronize { @destinations.delete(identity) }
      end

      private

      def new_identity
        identity = SecureRandom.random_bytes(8)
        identity.setbyte(0, identity.getbyte(0) & 0x7f)
        identity.setbyte(3, 1) if identity.unpack1("N").zero?
        identity
      end
    end
  end
end
