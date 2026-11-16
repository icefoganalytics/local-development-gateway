# frozen_string_literal: true

require "digest"

module LocalDevelopmentGateway
  def self.database_alias(project_name:, service_name:)
    unless project_name.is_a?(String) && project_name.ascii_only? &&
             /\A[a-z0-9][a-z0-9_-]*\z/.match?(project_name)
      raise ArgumentError,
            "project_name must be a nonempty lowercase ASCII Compose project name"
    end

    unless service_name.is_a?(String) && service_name.ascii_only? &&
             /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/.match?(service_name)
      raise ArgumentError,
            "service_name must be a nonempty ASCII Compose service name"
    end

    full_alias = "#{project_name}-#{service_name}"
    return full_alias if full_alias.bytesize <= 63

    # Permanent derivation: retain 38 characters plus a 96-bit SHA256 suffix.
    # NUL separates the original names so different partitions hash differently.
    suffix = Digest::SHA256.hexdigest("#{project_name}\0#{service_name}")[0, 24]
    "#{full_alias[0, 38]}-#{suffix}"
  end
end
