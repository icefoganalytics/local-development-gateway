# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/local_development_gateway"

class TlsClientHelloTest < Minitest::Test
  Router = LocalDevelopmentGateway::DatabaseRouter

  def test_reads_a_fragmented_tls_client_hello
    hello = tls_client_hello("db.issue-b.wrap.localhost")
    parser = Router::Tds::TlsClientHello.new

    refute parser.append(hello.byteslice(0, 10))
    assert_equal "db.issue-b.wrap.localhost",
                 parser.append(hello.byteslice(10..))
  end

  def test_rejects_oversized_tls_client_hello
    parser = Router::Tds::TlsClientHello.new

    error =
      assert_raises(LocalDevelopmentGateway::Error) do
        parser.append("x" * (Router::Tds::TlsClientHello::MAX_BYTES + 1))
      end

    assert_equal "TLS ClientHello is too large", error.message
  end

  private

  def tls_client_hello(hostname)
    server_name =
      [hostname.bytesize + 3, 0, hostname.bytesize].pack("nCn") + hostname
    extension = [0, server_name.bytesize].pack("nn") + server_name
    body =
      [0x0303].pack("n") + ("\0" * 32) + [0, 2, 0x1301, 1, 0].pack("CnnCC") +
        [extension.bytesize].pack("n") + extension
    handshake = [1].pack("C") + [body.bytesize].pack("N").byteslice(1, 3) + body
    [22, 0x0301, handshake.bytesize].pack("Cnn") + handshake
  end
end
