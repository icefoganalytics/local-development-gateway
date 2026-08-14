# frozen_string_literal: true

require "open3"
require "local_development_gateway/version"

module LocalDevelopmentGateway
  PROJECT_NAME = "local-gateway"
  NETWORK_NAME = "local-gateway"
  SERVICE_NAMES = %w[gateway database-router].freeze
  GATEWAY_LABEL = "local-gateway"
  OBSOLETE_SERVICE_NAMES = %w[dns tds-router].freeze
  ASSET_ROOT = File.expand_path("..", __dir__)
  COMPOSE_FILE = File.join(ASSET_ROOT, "docker-compose.yml")
  TRAEFIK_CONFIG_FILE = File.join(ASSET_ROOT, "config", "traefik.yml")

  class Error < StandardError
  end

  require "local_development_gateway/database_router"

  class DockerError < Error
    attr_reader :command, :output

    def initialize(command, output)
      @command = command
      @output = output
      super("Docker command failed: #{command.join(" ")}\n#{output}")
    end
  end

  class Docker
    def call(*args, capture: true)
      command = ["docker", *args]
      if capture
        stdout, stderr, status = Open3.capture3(*command)
        unless status.success?
          raise DockerError.new(command, stderr.empty? ? stdout : stderr)
        end

        stdout
      elsif system(*command)
        true
      else
        raise DockerError.new(command, "")
      end
    end
  end

  class Client
    CONTAINER_FORMAT =
      "{{.ID}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}\t{{.Label \"local-gateway\"}}"

    def initialize(
      runner: Docker.new,
      timeout: 30,
      poll_interval: 0.25,
      sleeper: ->(seconds) { sleep seconds },
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )
      @runner = runner
      @timeout = timeout
      @poll_interval = poll_interval
      @sleeper = sleeper
      @clock = clock
    end

    def ensure_running(*compose_args)
      return :reused if compose_args.empty? && ready?

      compose("up", "-d", "--remove-orphans", *compose_args)
      wait_until_ready
      :started
    end

    alias start ensure_running

    def ready?
      network_exists? && obsolete_services_absent? &&
        SERVICE_NAMES.all? do |service|
          gateway_container_ids(
            service: service,
            status: "running"
          ).any? { |id| healthy_container?(id) }
        end
    end

    def status
      compose("ps", "--all")
    end

    def logs(*args, follow: false)
      compose("logs", *(follow ? ["--follow"] : []), *args, capture: false)
    end

    def stop_if_unused
      return :not_running unless gateway_exists?
      return :in_use if non_gateway_containers_attached?

      compose("down", "--remove-orphans")
      :stopped
    end

    def with_running(ensure_running: true)
      begin
        self.ensure_running if ensure_running
        yield
      ensure
        block_error = $!
        begin
          stop_if_unused
        rescue StandardError => cleanup_error
          raise cleanup_error unless block_error
        end
      end
    end

    def compose(*args, capture: true)
      @runner.call(
        "compose",
        "--project-name",
        PROJECT_NAME,
        "--file",
        COMPOSE_FILE,
        *args,
        capture: capture
      )
    end

    private

    def wait_until_ready
      deadline = @clock.call + @timeout
      until ready?
        if @clock.call >= deadline
          raise Error, "Local Development Gateway did not become ready"
        end

        @sleeper.call(@poll_interval)
      end
    end

    def network_exists?
      labels =
        @runner.call(
          "network",
          "inspect",
          NETWORK_NAME,
          "--format",
          "{{index .Labels \"com.docker.compose.project\"}}\t{{index .Labels \"com.docker.compose.network\"}}"
        )
      labels.lines.any? do |line|
        line.strip == "#{PROJECT_NAME}\t#{NETWORK_NAME}"
      end
    rescue DockerError
      false
    end

    def gateway_exists?
      network_exists? &&
        SERVICE_NAMES.any? do |service|
          !gateway_container_ids(service: service).empty?
        end
    end

    def gateway_container_ids(service:, status: nil)
      args = ["ps"]
      args << "--all" unless status
      args.concat(
        [
          "--filter",
          "network=#{NETWORK_NAME}",
          "--filter",
          "label=com.docker.compose.project=#{PROJECT_NAME}",
          "--filter",
          "label=com.docker.compose.service=#{service}",
          "--filter",
          "label=#{GATEWAY_LABEL}=true"
        ]
      )
      args.push("--filter", "status=#{status}") if status
      output = @runner.call(*args, "--quiet")
      output.lines.map(&:strip).reject(&:empty?)
    end

    def obsolete_services_absent?
      OBSOLETE_SERVICE_NAMES.all? do |service|
        gateway_container_ids(service: service).empty?
      end
    end

    def healthy_container?(id)
      @runner.call(
        "inspect",
        "--format",
        "{{.State.Health.Status}}",
        id
      ).strip == "healthy"
    rescue DockerError
      false
    end

    def attached_containers
      output =
        @runner.call(
          "ps",
          "--filter",
          "network=#{NETWORK_NAME}",
          "--format",
          CONTAINER_FORMAT
        )
      output.lines.filter_map do |line|
        id, project, service, label = line.strip.split("\t", -1)
        next if id.nil? || id.empty?

        { id: id, project: project, service: service, label: label }
      end
    end

    def non_gateway_containers_attached?
      attached_containers.any? { |container| !gateway_container?(container) }
    end

    def gateway_container?(container)
      container[:project] == PROJECT_NAME &&
        SERVICE_NAMES.include?(container[:service]) &&
        container[:label] == "true"
    end
  end

  class CLI
    USAGE = <<~USAGE
      Usage: local-development-gateway COMMAND [OPTIONS]

      Commands:
        up, ensure  Start or reuse the shared gateway
        status      Show the gateway Compose status
        ready       Check gateway readiness
        logs        Follow gateway logs
        down, stop  Stop the gateway only when unused

      Other commands are passed to Docker Compose using the packaged assets.
    USAGE

    def self.run(argv, client: Client.new, output: $stdout, error: $stderr)
      new(argv, client: client, output: output, error: error).run
    end

    def initialize(argv, client:, output:, error:)
      @argv = argv.dup
      @client = client
      @output = output
      @error = error
    end

    def run
      command = @argv.shift
      if command.nil? || %w[help --help -h].include?(command)
        return print_usage(0)
      end

      case command
      when "up", "ensure"
        @client.ensure_running(*@argv)
      when "status"
        @output.write(@client.status)
      when "ready"
        return 0 if @client.ready?

        @error.puts "Local Development Gateway is not ready"
        return 1
      when "logs"
        @client.logs(*@argv, follow: true)
      when "down", "stop"
        report_stop(@client.stop_if_unused)
      else
        @output.write(@client.compose(command, *@argv))
      end
      0
    rescue Error => error
      @error.puts error.message
      1
    end

    private

    def print_usage(status)
      @output.write(USAGE)
      status
    end

    def report_stop(result)
      messages = {
        not_running: "Local Development Gateway is not running",
        in_use:
          "Leaving Local Development Gateway running because another container is attached",
        stopped: "Stopped Local Development Gateway"
      }
      @output.puts messages.fetch(result)
    end
  end

  class << self
    def ensure_running(*args)
      Client.new.ensure_running(*args)
    end

    def with_running(ensure_running: true, &block)
      Client.new.with_running(ensure_running: ensure_running, &block)
    end

    def start(*args)
      ensure_running(*args)
    end

    def ready?
      Client.new.ready?
    end

    def status
      Client.new.status
    end

    def logs(*args)
      Client.new.logs(*args, follow: true)
    end

    def stop_if_unused
      Client.new.stop_if_unused
    end
  end
end
