# frozen_string_literal: true

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
