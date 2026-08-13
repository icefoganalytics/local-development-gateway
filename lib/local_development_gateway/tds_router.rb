# frozen_string_literal: true

require "json"
require "socket"

module LocalDevelopmentGateway
  class TdsRouter
    LISTEN_PORT = 1433
    CONNECT_TIMEOUT = 3
    NETWORK_NAME = "local-gateway"
    HOSTNAME_LABEL = "local-gateway.tcp.hostname"
    PORT_LABEL = "local-gateway.tcp.port"

    Route = Data.define(:hostname, :port, :target_address)

    def self.run
      new.run
    end

    def initialize(
      routes: DockerRoutes.new,
      server: TCPServer.new("0.0.0.0", LISTEN_PORT)
    )
      @routes = routes
      @server = server
    end

    def run
      loop do
        client = @server.accept
        Thread.new(client) { |connection| route(connection) }
      end
    end

    def route(client)
      prelogin = TdsMessage.read(client)
      routes = @routes.call
      raise Error, "No labelled TDS routes are available" if routes.empty?
      provisional, target, response = negotiate(routes, prelogin)
      TdsMessage.write(client, response)

      client_hello = TdsMessage.read(client)
      hostname = TlsClientHello.server_name(client_hello.payload)
      selected = routes.find { |route| route.hostname == hostname }
      raise Error, "No TDS route for #{hostname}" unless selected

      if selected != provisional
        target.close
        target = connect(selected)
        TdsMessage.write(target, prelogin)
        TdsMessage.read(target)
      end

      TdsMessage.write(target, client_hello)
      proxy(client, target)
    rescue EOFError
      nil
    rescue Error => error
      warn error.message
    rescue StandardError => error
      warn error.full_message
    ensure
      client&.close
      target&.close
    end

    private

    def negotiate(routes, prelogin)
      routes.each do |route|
        target = connect(route)
        TdsMessage.write(target, prelogin)
        return route, target, TdsMessage.read(target)
      rescue Error, EOFError, IOError, SystemCallError
        target&.close
      end
      raise Error, "No labelled TDS backends are reachable"
    end

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
          rescue IOError, SystemCallError
            nil
          ensure
            destination.close_write unless destination.closed?
          end
        end
        .each(&:join)
    end

    class DockerRoutes
      def initialize(client: DockerApi.new)
        @client = client
      end

      def call
        routes =
          @client
            .get("/containers/json")
            .filter_map { |container| route(container) }
        hostnames = routes.map(&:hostname)
        unless hostnames.uniq.length == hostnames.length
          raise Error, "Duplicate labelled TDS hostname"
        end

        routes.sort_by(&:hostname)
      end

      private

      def route(container)
        labels = container.fetch("Labels")
        hostname = labels[HOSTNAME_LABEL]
        port = labels[PORT_LABEL]
        return unless hostname && port

        unless /\A(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+localhost\z/.match?(
                 hostname
               )
          raise Error, "Invalid labelled TDS hostname: #{hostname}"
        end

        port = Integer(port, 10)
        unless (1..65_535).cover?(port)
          raise Error, "Invalid labelled TDS port: #{port}"
        end

        target_address =
          container.dig(
            "NetworkSettings",
            "Networks",
            NETWORK_NAME,
            "IPAddress"
          )
        return if target_address.nil? || target_address.empty?

        Route.new(
          hostname: hostname,
          port: port,
          target_address: target_address
        )
      rescue ArgumentError, TypeError
        raise Error, "Invalid labelled TDS port: #{port}"
      end
    end

    class DockerApi
      SOCKET_PATH = "/var/run/docker.sock"

      def initialize(socket_path: SOCKET_PATH)
        @socket_path = socket_path
      end

      def get(path)
        socket = UNIXSocket.new(@socket_path)
        socket.write(
          "GET #{path} HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
        )
        headers, body = socket.read.split("\r\n\r\n", 2)
        unless headers&.start_with?("HTTP/1.1 200", "HTTP/1.0 200")
          raise Error,
                "Docker API request failed: #{headers&.lines&.first&.strip}"
        end

        body = decode_chunks(body) if headers.downcase.include?(
          "transfer-encoding: chunked"
        )
        JSON.parse(body)
      ensure
        socket&.close
      end

      private

      def decode_chunks(body)
        decoded = +""
        until body.start_with?("0\r\n")
          length, body = body.split("\r\n", 2)
          size = Integer(length, 16)
          decoded << body.byteslice(0, size)
          body = body.byteslice(size + 2..)
        end
        decoded
      end
    end

    class TdsMessage
      Packet = Data.define(:header, :payload)

      attr_reader :packets

      def self.read(io)
        packets = []
        loop do
          header = read_exactly(io, 8)
          length = header.byteslice(2, 2).unpack1("n")
          raise Error, "Invalid TDS packet length" if length < 8

          packets << Packet.new(
            header: header,
            payload: read_exactly(io, length - 8)
          )
          break if header.getbyte(1) & 1 == 1
        end
        new(packets)
      end

      def self.write(io, message)
        message.packets.each do |packet|
          io.write(packet.header, packet.payload)
        end
      end

      def self.read_exactly(io, length)
        bytes = io.read(length)
        raise EOFError unless bytes&.bytesize == length

        bytes
      end
      private_class_method :read_exactly

      def initialize(packets)
        @packets = packets
      end

      def payload
        packets.map(&:payload).join
      end
    end

    class TlsClientHello
      def self.server_name(bytes)
        offset = 5
        unless bytes.getbyte(0) == 22 && bytes.getbyte(offset) == 1
          raise Error, "Encrypted TDS connection with TLS SNI is required"
        end

        offset += 4 + 2 + 32
        offset += 1 + byte(bytes, offset)
        offset += 2 + uint16(bytes, offset)
        offset += 1 + byte(bytes, offset)
        finish = offset + 2 + uint16(bytes, offset)
        offset += 2

        while offset < finish
          type = uint16(bytes, offset)
          length = uint16(bytes, offset + 2)
          data = bytes.byteslice(offset + 4, length)
          return data.byteslice(5, uint16(data, 3)) if type.zero?

          offset += 4 + length
        end
        raise Error, "TLS ClientHello does not contain SNI"
      rescue NoMethodError, TypeError
        raise Error, "Invalid TLS ClientHello"
      end

      def self.byte(bytes, offset)
        bytes.getbyte(offset) || raise(Error, "Invalid TLS ClientHello")
      end
      private_class_method :byte

      def self.uint16(bytes, offset)
        bytes.byteslice(offset, 2).unpack1("n")
      end
      private_class_method :uint16
    end
  end
end
