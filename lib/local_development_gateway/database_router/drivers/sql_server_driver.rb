# frozen_string_literal: true

require "local_development_gateway/database_router/tds/message"
require "local_development_gateway/database_router/tds/tls_client_hello"

module LocalDevelopmentGateway
  module DatabaseRouter::Drivers
    class SqlServerDriver
      NEGOTIATION_ATTEMPT_TIMEOUT = 1

      NAME = "sql_server"
      LISTEN_PORT = 1433

      def name
        NAME
      end

      def listen_port
        LISTEN_PORT
      end

      def connect(client, routes:, connector:)
        deadline = DatabaseRouter::Wire.deadline
        prelogin = DatabaseRouter::Tds::Message.read(client, deadline: deadline)
        routes = routes.call
        if routes.empty?
          raise Error, "No labelled sql_server routes are available"
        end
        provisional, target, response =
          negotiate(routes, prelogin, connector, deadline)
        DatabaseRouter::Tds::Message.write(client, response)

        hostname, messages = read_client_hello(client, deadline)
        selected = routes.find { |route| route.hostname == hostname }
        raise Error, "No SQL Server route for #{hostname}" unless selected

        if selected != provisional
          target.close
          target = connector.call(selected, deadline: deadline)
          DatabaseRouter::Tds::Message.write(target, prelogin)
          DatabaseRouter::Tds::Message.read(target, deadline: deadline)
        end

        messages.each do |message|
          DatabaseRouter::Tds::Message.write(target, message)
        end
        DatabaseRouter::Connection.new(
          source: client,
          target: target,
          route: selected
        )
      rescue StandardError
        target&.close
        raise
      end

      def forward(connection)
        DatabaseRouter::Wire.proxy(connection.source, connection.target)
      end

      private

      def negotiate(routes, prelogin, connector, deadline)
        routes.each do |route|
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break unless remaining.positive?

          attempt_deadline = [
            deadline,
            Process.clock_gettime(Process::CLOCK_MONOTONIC) +
              NEGOTIATION_ATTEMPT_TIMEOUT
          ].min
          target = connector.call(route, deadline: attempt_deadline)
          DatabaseRouter::Tds::Message.write(target, prelogin)
          return [
            route,
            target,
            DatabaseRouter::Tds::Message.read(
              target,
              deadline: attempt_deadline
            )
          ]
        rescue Error, EOFError, IOError, SystemCallError
          target&.close
        end
        raise Error, "No labelled SQL Server backends are reachable"
      end

      def read_client_hello(client, deadline)
        hello = DatabaseRouter::Tds::TlsClientHello.new
        messages = []
        loop do
          message =
            DatabaseRouter::Tds::Message.read(client, deadline: deadline)
          messages << message
          hostname = hello.append(message.payload)
          return hostname, messages if hostname
        end
      end
    end
  end
end
