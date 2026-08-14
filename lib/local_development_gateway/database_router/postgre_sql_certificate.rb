# frozen_string_literal: true

require "openssl"

module LocalDevelopmentGateway
  class DatabaseRouter::PostgreSqlCertificate
    def initialize
      @key = OpenSSL::PKey::EC.generate("prime256v1")
      @certificate = OpenSSL::X509::Certificate.new
      @certificate.version = 2
      @certificate.serial = 1
      @certificate.subject =
        OpenSSL::X509::Name.parse("/CN=local-development-gateway")
      @certificate.issuer = @certificate.subject
      @certificate.public_key = @key
      @certificate.not_before = Time.now - 60
      @certificate.not_after = Time.now + (10 * 365 * 24 * 60 * 60)
      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = @certificate
      extensions.issuer_certificate = @certificate
      @certificate.add_extension(
        extensions.create_extension("basicConstraints", "CA:FALSE", true)
      )
      @certificate.add_extension(
        extensions.create_extension("keyUsage", "digitalSignature", true)
      )
      @certificate.add_extension(
        extensions.create_extension("extendedKeyUsage", "serverAuth")
      )
      @certificate.sign(@key, OpenSSL::Digest::SHA256.new)
    end

    def context(&servername_callback)
      context = OpenSSL::SSL::SSLContext.new
      context.cert = @certificate
      context.key = @key
      context.min_version = OpenSSL::SSL::TLS1_2_VERSION
      context.servername_cb = servername_callback
      context
    end
  end
end
