# frozen_string_literal: true

module LocalDevelopmentGateway
  class DatabaseRouter::Tds::TlsByteReader
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
