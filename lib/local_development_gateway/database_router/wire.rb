# frozen_string_literal: true

require "openssl"
require "socket"

module LocalDevelopmentGateway
  module DatabaseRouter::Wire
    HANDSHAKE_TIMEOUT = 5

    module_function

    def deadline
      Process.clock_gettime(Process::CLOCK_MONOTONIC) + HANDSHAKE_TIMEOUT
    end

    def read_exactly(io, length, deadline:)
      bytes = +""
      while bytes.bytesize < length
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Error, "Database handshake timed out" unless remaining.positive?

        chunk = io.read_nonblock(length - bytes.bytesize, exception: false)
        case chunk
        when :wait_readable
          wait(io, readable: true, deadline: deadline)
        when :wait_writable
          wait(io, readable: false, deadline: deadline)
        when nil
          raise EOFError
        else
          bytes << chunk
        end
      end
      bytes
    end

    def proxy(client, target, &response)
      upstream =
        Thread.new do
          IO.copy_stream(client, target)
        rescue IOError, EOFError, OpenSSL::SSL::SSLError, SystemCallError
          nil
        ensure
          close_write(target)
        end
      downstream =
        Thread.new do
          if response
            response.call(target, client)
          else
            IO.copy_stream(target, client)
          end
        rescue IOError, EOFError, OpenSSL::SSL::SSLError, SystemCallError
          nil
        ensure
          close_connection(client)
          close_connection(target)
        end
      threads = [upstream, downstream]
      threads.each { |thread| thread.report_on_exception = false }
      threads.each(&:join)
    ensure
      close_connection(client)
      close_connection(target)
      threads&.each(&:join)
    end

    def close_write(io)
      io.close_write unless io.closed?
    rescue IOError, SystemCallError
      nil
    end

    def close_connection(io)
      socket = io.to_io
      socket.shutdown(Socket::SHUT_RDWR) unless socket.closed?
    rescue IOError, SystemCallError
      nil
    ensure
      io.close unless io.closed?
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
