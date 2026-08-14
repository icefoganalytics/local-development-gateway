# frozen_string_literal: true

module LocalDevelopmentGateway
  class DatabaseRouter::Route < Data.define(
    :driver,
    :hostname,
    :port,
    :target_address
  )
  end
end
