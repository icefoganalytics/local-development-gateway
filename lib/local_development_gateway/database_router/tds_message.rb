# frozen_string_literal: true

module LocalDevelopmentGateway
  class DatabaseRouter::TdsMessage
    MAX_BYTES = 1024 * 1024
    MAX_PACKETS = 16

    attr_reader :packets

    def self.read(io, deadline:)
      packets = []
      size = 0
      loop do
        if packets.length >= MAX_PACKETS
          raise Error, "TDS message has too many packets"
        end

        header = DatabaseRouter::Wire.read_exactly(io, 8, deadline: deadline)
        length = header.byteslice(2, 2).unpack1("n")
        raise Error, "Invalid TDS packet length" if length < 8

        size += length - 8
        raise Error, "TDS message is too large" if size > MAX_BYTES

        packets << DatabaseRouter::TdsPacket.new(
          header: header,
          payload:
            DatabaseRouter::Wire.read_exactly(
              io,
              length - 8,
              deadline: deadline
            )
        )
        break if header.getbyte(1) & 1 == 1
      end
      new(packets)
    end

    def self.write(io, message)
      message.packets.each { |packet| io.write(packet.header, packet.payload) }
    end

    def initialize(packets)
      @packets = packets
    end

    def payload
      packets.map(&:payload).join
    end
  end
end
