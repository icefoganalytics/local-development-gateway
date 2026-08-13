# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "socket"

module LocalDevelopmentGateway
  class HostAgent
    NETWORK_NAME = "local-gateway"
    HOSTNAME_LABEL = "local-gateway.tcp.hostname"
    PORT_LABEL = "local-gateway.tcp.port"
    ADDRESS_PREFIX = "127.77.0"
    POLL_INTERVAL = 1

    Route =
      Data.define(:container_id, :hostname, :port, :target_address, :address)

    def initialize(
      runner: Docker.new,
      state_dir: "/var/lib/local-development-gateway",
      hosts_path: "/etc/hosts",
      sleeper: ->(seconds) { sleep seconds }
    )
      @routes = DockerRoutes.new(runner: runner)
      @registry = Registry.new(state_dir: state_dir, hosts_path: hosts_path)
      @listeners = Listeners.new
      @sleeper = sleeper
      @stopping = false
    end

    def run
      require_root
      Signal.trap("TERM") { @stopping = true }
      Signal.trap("INT") { @stopping = true }

      begin
        until @stopping
          begin
            reconcile
            @sleeper.call(POLL_INTERVAL)
          rescue StandardError => error
            warn error.full_message
            @sleeper.call(POLL_INTERVAL)
          end
        end
      ensure
        @listeners.reconcile([])
        @registry.reconcile([])
      end
    end

    def reconcile
      @listeners.reconcile(@registry.reconcile(@routes.call))
    end

    private

    def require_root
      unless Process.uid.zero?
        raise Error, "The Local Development Gateway host agent must run as root"
      end
    end

    class DockerRoutes
      FORMAT =
        "{{.ID}}\t{{.Label \"#{HOSTNAME_LABEL}\"}}\t{{.Label \"#{PORT_LABEL}\"}}"

      def initialize(runner:)
        @runner = runner
      end

      def call
        containers.filter_map do |container_id, hostname, port|
          target_address = inspect_address(container_id)
          next if target_address.empty?

          Route.new(
            container_id: container_id,
            hostname: hostname,
            port: Integer(port, 10),
            target_address: target_address,
            address: nil
          )
        end
      end

      private

      def containers
        @runner
          .call(
            "ps",
            "--filter",
            "network=#{NETWORK_NAME}",
            "--filter",
            "label=#{HOSTNAME_LABEL}",
            "--filter",
            "label=#{PORT_LABEL}",
            "--format",
            FORMAT
          )
          .lines
          .map { |line| line.strip.split("\t", -1) }
      end

      def inspect_address(container_id)
        @runner.call(
          "inspect",
          "--format",
          "{{with index .NetworkSettings.Networks \"#{NETWORK_NAME}\"}}{{.IPAddress}}{{end}}",
          container_id
        ).strip
      end
    end

    class Registry
      BEGIN_MARKER = "# BEGIN local-development-gateway"
      END_MARKER = "# END local-development-gateway"

      def initialize(state_dir:, hosts_path:)
        @state_dir = state_dir
        @hosts_path = hosts_path
      end

      def reconcile(routes)
        validate(routes)
        FileUtils.mkdir_p(@state_dir)
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          state = read_state
          active_hostnames = routes.map(&:hostname)
          state.select! do |hostname, _address|
            active_hostnames.include?(hostname)
          end
          assigned =
            routes.map do |route|
              address =
                state.fetch(route.hostname) do
                  state[route.hostname] = next_address(state)
                end
              Route.new(**route.to_h, address: address)
            end
          write_state(state)
          write_hosts(assigned)
          assigned
        end
      end

      private

      def validate(routes)
        hostnames = routes.map(&:hostname)
        unless hostnames.uniq.length == hostnames.length
          raise Error, "Duplicate local TCP hostname"
        end

        routes.each do |route|
          unless /\A(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+localhost\z/.match?(
                   route.hostname
                 )
            raise Error, "Invalid local TCP hostname: #{route.hostname}"
          end
          unless (1_024..65_535).cover?(route.port)
            raise Error, "Invalid local TCP port: #{route.port}"
          end
        end
      end

      def next_address(state)
        1.upto(254) do |host|
          address = "#{ADDRESS_PREFIX}.#{host}"
          return address unless state.value?(address)
        end
        raise Error, "No local TCP route addresses remain"
      end

      def read_state
        return {} unless File.exist?(state_path)

        JSON.parse(File.read(state_path))
      end

      def write_state(state)
        File.write(state_path, JSON.generate(state))
      end

      def write_hosts(routes)
        content = File.read(@hosts_path)
        starts = content.scan(/^#{Regexp.escape(BEGIN_MARKER)}$/).length
        ends = content.scan(/^#{Regexp.escape(END_MARKER)}$/).length
        unless starts == ends && starts <= 1
          raise Error,
                "Invalid Local Development Gateway block in #{@hosts_path}"
        end

        records =
          routes
            .sort_by(&:hostname)
            .map { |route| "#{route.address} #{route.hostname}" }
        block = [BEGIN_MARKER, *records, END_MARKER].join("\n")
        if starts == 1
          content.sub!(
            /^#{Regexp.escape(BEGIN_MARKER)}$.*?^#{Regexp.escape(END_MARKER)}$/m,
            block
          )
        else
          content =
            "#{content}#{content.end_with?("\n") ? "\n" : "\n\n"}#{block}\n"
        end
        File.write(@hosts_path, content)
      end

      def lock_path
        File.join(@state_dir, "host-agent.lock")
      end

      def state_path
        File.join(@state_dir, "host-agent.json")
      end
    end

    class Listeners
      def initialize
        @routes = {}
        @servers = {}
        @mutex = Mutex.new
      end

      def reconcile(routes)
        next_routes =
          routes.to_h { |route| [[route.address, route.port], route] }
        unless next_routes.length == routes.length
          raise Error, "Two local TCP routes require the same address and port"
        end

        @mutex.synchronize { @routes = next_routes }
        (@servers.keys - next_routes.keys).each do |key|
          @servers.delete(key).close
        end
        (next_routes.keys - @servers.keys).each do |key|
          @servers[key] = listen(key)
        end
      end

      private

      def listen(key)
        server = TCPServer.new(*key)
        Thread.new do
          loop do
            client = server.accept
            Thread.new(client) { |connection| proxy(connection, key) }
          rescue IOError, Errno::EBADF
            break
          end
        end
        server
      end

      def proxy(client, key)
        route = @mutex.synchronize { @routes.fetch(key) }
        target = TCPSocket.new(route.target_address, route.port)
        [[client, target], [target, client]].map do |source, destination|
            Thread.new do
              IO.copy_stream(source, destination)
            rescue IOError, SystemCallError
              nil
            ensure
              destination.close_write unless destination.closed?
            end
          end
          .each(&:join)
      ensure
        client&.close
        target&.close
      end
    end

    class Installer
      SERVICE_NAME = "local-development-gateway-host-agent.service"
      UNIT_PATH = File.join("/etc/systemd/system", SERVICE_NAME)

      def self.install(
        executable: File.realpath($PROGRAM_NAME),
        ruby: RbConfig.ruby,
        unit_path: UNIT_PATH,
        command: Command.new
      )
        require_root
        File.write(unit_path, unit(executable: executable, ruby: ruby))
        command.call("systemctl", "daemon-reload")
        command.call("systemctl", "enable", SERVICE_NAME)
        command.call("systemctl", "restart", SERVICE_NAME)
      end

      def self.uninstall(unit_path: UNIT_PATH, command: Command.new)
        require_root
        command.call("systemctl", "disable", "--now", SERVICE_NAME)
        FileUtils.rm_f(unit_path)
        command.call("systemctl", "daemon-reload")
        Registry.new(
          state_dir: "/var/lib/local-development-gateway",
          hosts_path: "/etc/hosts"
        ).reconcile([])
      end

      def self.unit(executable:, ruby:)
        [executable, ruby].each do |path|
          if /\s/.match?(path)
            raise Error, "Host agent paths cannot contain whitespace"
          end
        end

        <<~UNIT
          [Unit]
          Description=Local Development Gateway TCP host agent
          After=docker.service
          Requires=docker.service

          [Service]
          Type=simple
          ExecStart=#{ruby} #{executable} host-agent
          Restart=on-failure
          RestartSec=1
          NoNewPrivileges=true
          PrivateTmp=true
          ProtectHome=read-only
          ProtectSystem=strict
          ReadWritePaths=/etc/hosts /var/lib/local-development-gateway
          RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

          [Install]
          WantedBy=multi-user.target
        UNIT
      end

      def self.require_root
        raise Error, "Run this command with sudo" unless Process.uid.zero?
      end
      private_class_method :require_root
    end

    class Command
      def call(*args)
        return true if system(*args)

        raise Error, "Command failed: #{args.join(" ")}"
      end
    end
  end
end
