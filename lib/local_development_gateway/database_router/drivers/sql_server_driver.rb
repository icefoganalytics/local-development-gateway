# frozen_string_literal: true

require_relative "../tds/message"
require_relative "../tds/tls_client_hello"

module LocalDevelopmentGateway
  class DatabaseRouter::SqlServerDriver
    NAME = "sql_server"
    LISTEN_PORT = 1433

    def name
      NAME
    end

    def listen_port
      LISTEN_PORT
    end

    def connect(client, routes, connector:)
      deadline = DatabaseRouter::Wire.deadline
      prelogin = DatabaseRouter::Tds::Message.read(client, deadline: deadline)
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
        target = connector.call(selected)
        DatabaseRouter::Tds::Message.write(target, prelogin)
        DatabaseRouter::Tds::Message.read(target, deadline: deadline)
      end

      messages.each do |message|
        DatabaseRouter::Tds::Message.write(target, message)
      end
      [client, target]
    rescue StandardError
      target&.close
      raise
    end

    private

    def negotiate(routes, prelogin, connector, deadline)
      routes.each do |route|
        target = connector.call(route)
        DatabaseRouter::Tds::Message.write(target, prelogin)
        return [
          route,
          target,
          DatabaseRouter::Tds::Message.read(target, deadline: deadline)
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
        message = DatabaseRouter::Tds::Message.read(client, deadline: deadline)
        messages << message
        hostname = hello.append(message.payload)
        return hostname, messages if hostname
      end
    end
  end
end
