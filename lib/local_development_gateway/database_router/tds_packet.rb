# frozen_string_literal: true

module LocalDevelopmentGateway
  class DatabaseRouter::TdsPacket < Data.define(:header, :payload)
  end
end
