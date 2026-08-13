# frozen_string_literal: true

require "json"
require "openssl"
require "socket"

module LocalDevelopmentGateway
  class DatabaseRouter
    CONNECT_TIMEOUT = 3
    HANDSHAKE_TIMEOUT = 5
    MAX_CONNECTIONS = 128
    MAX_CLIENT_HELLO_BYTES = 128 * 1024
    MAX_DOCKER_RESPONSE_BYTES = 8 * 1024 * 1024
    MAX_TDS_MESSAGE_BYTES = 1024 * 1024
    MAX_TDS_PACKETS = 16
    MAX_TLS_RECORD_BYTES = (16 * 1024) + 2048
    NETWORK_NAME = "local-gateway"
    HOSTNAME_LABEL = "local-gateway.tcp.hostname"
    PORT_LABEL = "local-gateway.tcp.port"
    DRIVER_LABEL = "local-gateway.tcp.driver"
    HOSTNAME_PATTERN = /\A(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+localhost\z/

    Route = Data.define(:driver, :hostname, :port, :target_address)

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

    class SqlServerDriver
      NAME = "sql_server"
      LISTEN_PORT = 1433

      def name
        NAME
      end

      def listen_port
        LISTEN_PORT
      end

      def connect(client, routes, connector:)
        deadline = Wire.deadline
        prelogin = TdsMessage.read(client, deadline: deadline)
        if routes.empty?
          raise Error, "No labelled sql_server routes are available"
        end
        provisional, target, response =
          negotiate(routes, prelogin, connector, deadline)
        TdsMessage.write(client, response)

        hostname, messages = read_client_hello(client, deadline)
        selected = routes.find { |route| route.hostname == hostname }
        raise Error, "No SQL Server route for #{hostname}" unless selected

        if selected != provisional
          target.close
          target = connector.call(selected)
          TdsMessage.write(target, prelogin)
          TdsMessage.read(target, deadline: deadline)
        end

        messages.each { |message| TdsMessage.write(target, message) }
        [client, target]
      rescue StandardError
        target&.close
        raise
      end

      private

      def negotiate(routes, prelogin, connector, deadline)
        routes.each do |route|
          target = connector.call(route)
          TdsMessage.write(target, prelogin)
          return route, target, TdsMessage.read(target, deadline: deadline)
        rescue Error, EOFError, IOError, SystemCallError
          target&.close
        end
        raise Error, "No labelled SQL Server backends are reachable"
      end

      def read_client_hello(client, deadline)
        hello = TlsClientHello.new
        messages = []
        loop do
          message = TdsMessage.read(client, deadline: deadline)
          messages << message
          hostname = hello.append(message.payload)
          return hostname, messages if hostname
        end
      end
    end

    class PostgreSqlDriver
      NAME = "postgresql"
      LISTEN_PORT = 5432
      SSL_REQUEST = [8, 80_877_103].pack("NN").freeze

      def initialize(certificate: Certificate.new)
        @certificate = certificate
      end

      def name
        NAME
      end

      def listen_port
        LISTEN_PORT
      end

      def connect(client, routes, connector:)
        deadline = Wire.deadline
        request =
          Wire.read_exactly(client, SSL_REQUEST.bytesize, deadline: deadline)
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
        Wire.accept_tls(tls, deadline: deadline)
        unless hostname
          raise Error, "PostgreSQL TLS ClientHello does not contain SNI"
        end

        selected = routes.find { |route| route.hostname == hostname }
        raise Error, "No PostgreSQL route for #{hostname}" unless selected

        [tls, connector.call(selected)]
      end

      class Certificate
        def initialize
          @key = OpenSSL::PKey::EC.generate("prime256v1")
          @certificate = OpenSSL::X509::Certificate.new
          @certificate.version = 2
          @certificate.serial = 1
          @certificate.subject =
            OpenSSL::X509::Name.parse("/CN=local-development-gateway")
          @certificate.issuer = @certificate.subject
          @certificate.public_key = @key
          @certificate.not_before = Time.now - 60
          @certificate.not_after = Time.now + (10 * 365 * 24 * 60 * 60)
          extensions = OpenSSL::X509::ExtensionFactory.new
          extensions.subject_certificate = @certificate
          extensions.issuer_certificate = @certificate
          @certificate.add_extension(
            extensions.create_extension("basicConstraints", "CA:FALSE", true)
          )
          @certificate.add_extension(
            extensions.create_extension("keyUsage", "digitalSignature", true)
          )
          @certificate.add_extension(
            extensions.create_extension("extendedKeyUsage", "serverAuth")
          )
          @certificate.sign(@key, OpenSSL::Digest::SHA256.new)
        end

        def context(&servername_callback)
          context = OpenSSL::SSL::SSLContext.new
          context.cert = @certificate
          context.key = @key
          context.min_version = OpenSSL::SSL::TLS1_2_VERSION
          context.servername_cb = servername_callback
          context
        end
      end
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
        identities = routes.map { |route| [route.driver, route.hostname] }
        unless identities.uniq.length == identities.length
          raise Error, "Duplicate labelled database hostname"
        end

        routes.sort_by { |route| [route.driver, route.hostname] }
      end

      private

      def route(container)
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

        target_address =
          container.dig(
            "NetworkSettings",
            "Networks",
            NETWORK_NAME,
            "IPAddress"
          )
        return if target_address.nil? || target_address.empty?

        Route.new(
          driver: driver,
          hostname: hostname,
          port: port,
          target_address: target_address
        )
      rescue ArgumentError, TypeError
        raise Error, "Invalid labelled database port: #{port}"
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
        response =
          Wire.read_until_eof(
            socket,
            max_bytes: MAX_DOCKER_RESPONSE_BYTES,
            deadline: Wire.deadline
          )
        headers, body = response.split("\r\n\r\n", 2)
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
        loop do
          line_end = body.index("\r\n")
          raise Error, "Invalid chunked Docker API response" unless line_end

          size = Integer(body.byteslice(0, line_end).split(";", 2).first, 16)
          body = body.byteslice(line_end + 2..)
          break if size.zero?
          unless body.bytesize >= size + 2 && body.byteslice(size, 2) == "\r\n"
            raise Error, "Invalid chunked Docker API response"
          end

          decoded << body.byteslice(0, size)
          body = body.byteslice(size + 2..)
        end
        decoded
      rescue ArgumentError, TypeError
        raise Error, "Invalid chunked Docker API response"
      end
    end

    class TdsMessage
      Packet = Data.define(:header, :payload)

      attr_reader :packets

      def self.read(io, deadline:)
        packets = []
        size = 0
        loop do
          if packets.length >= MAX_TDS_PACKETS
            raise Error, "TDS message has too many packets"
          end

          header = Wire.read_exactly(io, 8, deadline: deadline)
          length = header.byteslice(2, 2).unpack1("n")
          raise Error, "Invalid TDS packet length" if length < 8

          size += length - 8
          if size > MAX_TDS_MESSAGE_BYTES
            raise Error, "TDS message is too large"
          end

          packets << Packet.new(
            header: header,
            payload: Wire.read_exactly(io, length - 8, deadline: deadline)
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

      def initialize(packets)
        @packets = packets
      end

      def payload
        packets.map(&:payload).join
      end
    end

    class TlsClientHello
      def initialize
        @record_buffer = +""
        @handshake = +""
        @received = 0
      end

      def append(bytes)
        @received += bytes.bytesize
        if @received > MAX_CLIENT_HELLO_BYTES
          raise Error, "TLS ClientHello is too large"
        end

        @record_buffer << bytes
        consume_records
        server_name if complete?
      end

      private

      def consume_records
        while @record_buffer.bytesize >= 5
          content_type = @record_buffer.getbyte(0)
          length = @record_buffer.byteslice(3, 2).unpack1("n")
          unless content_type == 22
            raise Error, "Invalid TLS ClientHello record"
          end
          if length > MAX_TLS_RECORD_BYTES
            raise Error, "TLS record is too large"
          end
          break if @record_buffer.bytesize < length + 5

          @handshake << @record_buffer.byteslice(5, length)
          @record_buffer = @record_buffer.byteslice(length + 5..) || +""
        end
      end

      def complete?
        return false if @handshake.bytesize < 4
        unless @handshake.getbyte(0) == 1
          raise Error, "Expected a TLS ClientHello"
        end

        @handshake.bytesize >= 4 + uint24(@handshake, 1)
      end

      def server_name
        length = uint24(@handshake, 1)
        reader = ByteReader.new(@handshake.byteslice(4, length))
        reader.read(2 + 32)
        reader.vector8
        reader.vector16
        reader.vector8
        extensions = ByteReader.new(reader.vector16)
        until extensions.empty?
          type = extensions.uint16
          data = extensions.vector16
          next unless type.zero?

          names = ByteReader.new(ByteReader.new(data).vector16)
          until names.empty?
            name_type = names.uint8
            name = names.vector16
            if name_type.zero?
              return name.force_encoding(Encoding::UTF_8).downcase
            end
          end
        end
        raise Error, "TLS ClientHello does not contain SNI"
      end

      def uint24(bytes, offset)
        (bytes.getbyte(offset) << 16) | (bytes.getbyte(offset + 1) << 8) |
          bytes.getbyte(offset + 2)
      rescue NoMethodError
        raise Error, "Invalid TLS ClientHello"
      end

      class ByteReader
        def initialize(bytes)
          @bytes = bytes
          @offset = 0
        end

        def empty?
          @offset == @bytes.bytesize
        end

        def read(length)
          if length.negative? || @offset + length > @bytes.bytesize
            raise Error, "Invalid TLS ClientHello"
          end

          value = @bytes.byteslice(@offset, length)
          @offset += length
          value
        end

        def uint8
          read(1).unpack1("C")
        end

        def uint16
          read(2).unpack1("n")
        end

        def vector8
          read(uint8)
        end

        def vector16
          read(uint16)
        end
      end
    end

    module Wire
      module_function

      def deadline
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + HANDSHAKE_TIMEOUT
      end

      def read_exactly(io, length, deadline:)
        bytes = +""
        while bytes.bytesize < length
          wait(io, readable: true, deadline: deadline)
          bytes << io.readpartial(length - bytes.bytesize)
        end
        bytes
      end

      def read_until_eof(io, max_bytes:, deadline:)
        bytes = +""
        loop do
          wait(io, readable: true, deadline: deadline)
          bytes << io.readpartial(16 * 1024)
          raise Error, "Response is too large" if bytes.bytesize > max_bytes
        end
      rescue EOFError
        bytes
      end

      def accept_tls(socket, deadline:)
        loop do
          case socket.accept_nonblock(exception: false)
          when :wait_readable
            wait(socket, readable: true, deadline: deadline)
          when :wait_writable
            wait(socket, readable: false, deadline: deadline)
          else
            return socket
          end
        end
      rescue OpenSSL::SSL::SSLError => error
        raise Error, "PostgreSQL TLS handshake failed: #{error.message}"
      end

      def wait(io, readable:, deadline:)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ready =
          remaining.positive? &&
            IO.select(
              readable ? [io] : nil,
              readable ? nil : [io],
              nil,
              remaining
            )
        raise Error, "Database handshake timed out" unless ready
      end
    end
  end
end
