# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "local_development_gateway"

class WireTest < Minitest::Test
  Router = LocalDevelopmentGateway::DatabaseRouter

  def test_database_handshake_reads_have_one_deadline
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)

    error =
      assert_raises(LocalDevelopmentGateway::Error) do
        Router::Wire.read_exactly(reader, 1, deadline: 0)
      end

    assert_equal "Database handshake timed out", error.message
  ensure
    reader&.close
    writer&.close
  end
end
