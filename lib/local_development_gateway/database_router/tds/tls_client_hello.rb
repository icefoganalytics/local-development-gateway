# frozen_string_literal: true

require_relative "tls_byte_reader"

module LocalDevelopmentGateway
  class DatabaseRouter::Tds::TlsClientHello
    MAX_BYTES = 128 * 1024
    MAX_RECORD_BYTES = (16 * 1024) + 2048

    def initialize
      @record_buffer = +""
      @handshake = +""
      @received = 0
    end

    def append(bytes)
      @received += bytes.bytesize
      raise Error, "TLS ClientHello is too large" if @received > MAX_BYTES

      @record_buffer << bytes
      consume_records
      server_name if complete?
    end

    private

    def consume_records
      while @record_buffer.bytesize >= 5
        content_type = @record_buffer.getbyte(0)
        length = @record_buffer.byteslice(3, 2).unpack1("n")
        raise Error, "Invalid TLS ClientHello record" unless content_type == 22
        raise Error, "TLS record is too large" if length > MAX_RECORD_BYTES
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
      reader =
        DatabaseRouter::Tds::TlsByteReader.new(@handshake.byteslice(4, length))
      reader.read(2 + 32)
      reader.vector8
      reader.vector16
      reader.vector8
      extensions = DatabaseRouter::Tds::TlsByteReader.new(reader.vector16)
      until extensions.empty?
        type = extensions.uint16
        data = extensions.vector16
        next unless type.zero?

        names =
          DatabaseRouter::Tds::TlsByteReader.new(
            DatabaseRouter::Tds::TlsByteReader.new(data).vector16
          )
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
  end
end
