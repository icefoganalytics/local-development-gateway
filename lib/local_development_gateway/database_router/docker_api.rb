# frozen_string_literal: true

require "json"
require "socket"

require_relative "wire"

module LocalDevelopmentGateway
  class DatabaseRouter::DockerApi
    MAX_RESPONSE_BYTES = 8 * 1024 * 1024
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
        DatabaseRouter::Wire.read_until_eof(
          socket,
          max_bytes: MAX_RESPONSE_BYTES,
          deadline: DatabaseRouter::Wire.deadline
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
end
