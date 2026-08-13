# frozen_string_literal: true

require "fileutils"
require "json"

module LocalDevelopmentGateway
  class TcpEndpoint
    attr_reader :address, :hostname

    def initialize(address:, hostname:)
      @address = address
      @hostname = hostname
    end
  end

  class TcpEndpoints
    DOMAIN = "gateway.test"
    ADDRESS_PREFIX = "127.77"

    def initialize(
      state_dir: ENV.fetch(
        "LOCAL_DEVELOPMENT_GATEWAY_STATE_DIR",
        File.join(Dir.home, ".local", "state", "local-development-gateway")
      )
    )
      @state_dir = state_dir
    end

    def register(worktree: Dir.pwd, service: "db")
      path = File.realpath(worktree)
      name = hostname_label(File.basename(path))
      service = hostname_label(service)

      with_state do |state|
        endpoint =
          state.fetch(path) do
            state[path] = { "address" => next_address(state), "services" => [] }
          end
        unless endpoint.fetch("services").include?(service)
          endpoint.fetch("services") << service
        end
        write_hosts(state)
        TcpEndpoint.new(
          address: endpoint.fetch("address"),
          hostname: "#{service}.#{name}.#{DOMAIN}"
        )
      end
    end

    def release(worktree: Dir.pwd, service: "db")
      path = File.realpath(worktree)
      service = hostname_label(service)

      with_state do |state|
        endpoint = state[path]
        return unless endpoint

        endpoint.fetch("services").delete(service)
        state.delete(path) if endpoint.fetch("services").empty?
        write_hosts(state)
      end
    end

    def ensure_hosts_file
      with_state { |state| write_hosts(state) }
    end

    private

    def with_state
      FileUtils.mkdir_p(@state_dir)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        state = File.exist?(state_path) ? JSON.parse(File.read(state_path)) : {}
        result = yield(state)
        File.write(state_path, JSON.generate(state))
        result
      end
    end

    def next_address(state)
      addresses = state.values.map { |endpoint| endpoint.fetch("address") }
      1.upto(254) do |host|
        address = "#{ADDRESS_PREFIX}.0.#{host}"
        return address unless addresses.include?(address)
      end
      raise Error, "No loopback TCP addresses remain"
    end

    def write_hosts(state)
      records =
        state.flat_map do |path, endpoint|
          name = hostname_label(File.basename(path))
          endpoint
            .fetch("services")
            .map do |service|
              "#{endpoint.fetch("address")} #{service}.#{name}.#{DOMAIN}"
            end
        end
      File.write(
        hosts_path,
        records.sort.join("\n") + (records.empty? ? "" : "\n")
      )
    end

    def hostname_label(value)
      label = value.to_s.downcase.tr("_", "-")
      unless /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/.match?(label)
        raise Error, "Invalid gateway hostname label: #{value}"
      end
      label
    end

    def lock_path
      File.join(@state_dir, "tcp-endpoints.lock")
    end

    def state_path
      File.join(@state_dir, "tcp-endpoints.json")
    end

    def hosts_path
      File.join(@state_dir, "hosts")
    end
  end
end
