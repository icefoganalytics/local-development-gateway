# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"
require_relative "../lib/local_development_gateway"

class LocalDevelopmentGatewayTest < Minitest::Test
  class FakeRunner
    attr_reader :calls

    def initialize(
      network_labels: "local-gateway\tlocal-gateway\n",
      gateway_ids: "gateway-id\n",
      obsolete_ids: "",
      health: "healthy\n",
      attached: "gateway-id\tlocal-gateway\tgateway\ttrue\n",
      all_attached: attached,
      compose_error: nil,
      startup_error: nil
    )
      @network_labels = network_labels
      @gateway_ids = gateway_ids
      @obsolete_ids = obsolete_ids
      @health = health
      @attached = attached
      @all_attached = all_attached
      @compose_error = compose_error
      @startup_error = startup_error
      @calls = []
    end

    def call(*args, capture: true)
      @calls << { args: args, capture: capture }
      case args.first
      when "network"
        if @network_labels.nil?
          raise LocalDevelopmentGateway::DockerError.new(args, "missing")
        end

        @network_labels
      when "ps"
        if args.include?("--format")
          (args.include?("--all") ? @all_attached : @attached)
        elsif args.include?("label=com.docker.compose.service=dns")
          @obsolete_ids
        else
          @gateway_ids
        end
      when "inspect"
        @health
      when "compose"
        raise @compose_error if @compose_error && args.include?("down")
        if @startup_error && args.include?("up")
          @gateway_ids = "gateway-id\n"
          raise @startup_error
        end

        if args.include?("up")
          @gateway_ids = "gateway-id\n"
          @obsolete_ids = ""
        end
        ""
      end
    end
  end

  def test_assets_are_packaged_with_the_gem
    spec =
      Gem::Specification.load(
        File.expand_path("../local-development-gateway.gemspec", __dir__)
      )
    gem_path = File.join(Dir.mktmpdir, "local-development-gateway.gem")
    _stdout, stderr, status =
      Open3.capture3("gem", "build", spec.loaded_from, "--output", gem_path)

    assert status.success?, stderr
    assert_includes Gem::Package.new(gem_path).contents, "config/traefik.yml"
    assert_includes Gem::Package.new(gem_path).contents, "docker-compose.yml"
    assert_includes Gem::Package.new(gem_path).contents,
                    "lib/local_development_gateway/host_agent.rb"
  end

  def test_installed_gem_resolves_packaged_asset_paths
    gem_path = build_gem
    gem_home = Dir.mktmpdir
    _stdout, stderr, status =
      Open3.capture3(
        "gem",
        "install",
        "--local",
        "--no-document",
        "--install-dir",
        gem_home,
        gem_path
      )
    assert status.success?, stderr
    script = <<~RUBY
      require "local_development_gateway"
      puts LocalDevelopmentGateway::COMPOSE_FILE
      puts LocalDevelopmentGateway::TRAEFIK_CONFIG_FILE
    RUBY

    stdout, stderr, status =
      Open3.capture3(
        { "GEM_HOME" => gem_home, "GEM_PATH" => gem_home },
        RbConfig.ruby,
        "-e",
        script
      )

    assert status.success?, stderr
    compose_file, traefik_file = stdout.lines.map(&:strip)
    assert File.file?(compose_file)
    assert File.file?(traefik_file)
  end

  def test_rejects_a_network_with_the_wrong_compose_scope
    runner = FakeRunner.new(network_labels: "other-project\tlocal-gateway\n")

    refute client(runner).ready?
  end

  def test_requires_a_healthy_gateway_container
    runner = FakeRunner.new(health: "starting\n")

    refute client(runner).ready?
  end

  def test_stops_an_unhealthy_gateway_when_no_consumer_is_attached
    runner = FakeRunner.new(health: "starting\n")

    assert_equal :stopped, client(runner).stop_if_unused
    assert runner.calls.any? { |call| call[:args].include?("down") }
  end

  def test_reuses_a_ready_gateway
    runner = FakeRunner.new

    assert_equal :reused, client(runner).ensure_running
    assert_empty runner.calls.select { |call| call[:args].first == "compose" }
  end

  def test_recreates_gateway_to_remove_obsolete_services
    runner = FakeRunner.new(obsolete_ids: "dns-id\n")

    assert_equal :started, client(runner).ensure_running
    assert runner.calls.any? { |call| call[:args].include?("up") }
  end

  def test_starts_and_waits_for_a_ready_gateway
    runner = FakeRunner.new(gateway_ids: "")

    assert_equal :started, client(runner).ensure_running
    assert runner.calls.any? { |call| call[:args].include?("up") }
  end

  def test_preserves_gateway_when_a_running_attached_container_exists
    runner = FakeRunner.new(attached: <<~CONTAINERS)
      gateway-id\tlocal-gateway\tgateway\ttrue
      consumer-id\tconsumer-project\tweb\t
    CONTAINERS

    assert_equal :in_use, client(runner).stop_if_unused
    refute runner.calls.any? { |call| call[:args].include?("down") }
  end

  def test_stops_gateway_when_an_exited_attached_container_exists
    runner = FakeRunner.new(all_attached: <<~CONTAINERS)
      gateway-id\tlocal-gateway\tgateway\ttrue
      consumer-id\tconsumer-project\tweb\t
    CONTAINERS

    assert_equal :stopped, client(runner).stop_if_unused
  end

  def test_stops_gateway_when_a_created_attached_container_exists
    runner = FakeRunner.new(all_attached: <<~CONTAINERS)
      gateway-id\tlocal-gateway\tgateway\ttrue
      consumer-id\tconsumer-project\tweb\t
    CONTAINERS

    assert_equal :stopped, client(runner).stop_if_unused
  end

  def test_stops_the_last_gateway_when_only_gateway_container_remains
    runner = FakeRunner.new

    assert_equal :stopped, client(runner).stop_if_unused
    assert runner.calls.any? { |call| call[:args].include?("down") }
  end

  def test_with_running_returns_the_block_result_and_stops_started_gateway
    runner = FakeRunner.new(gateway_ids: "")

    result = client(runner).with_running { :result }

    assert_equal :result, result
    assert runner.calls.any? { |call| call[:args].include?("down") }
  end

  def test_with_running_reuses_a_ready_gateway_and_cleans_it_up
    runner = FakeRunner.new

    client(runner).with_running { :result }

    refute runner.calls.any? { |call| call[:args].include?("up") }
    assert runner.calls.any? { |call| call[:args].include?("down") }
  end

  def test_with_running_runs_without_starting_a_missing_gateway
    runner = FakeRunner.new(network_labels: nil, gateway_ids: "")

    result = client(runner).with_running(ensure_running: false) { :result }

    assert_equal :result, result
    refute runner.calls.any? { |call| call[:args].include?("up") }
  end

  def test_with_running_cleans_up_an_existing_gateway_without_starting
    runner = FakeRunner.new

    result = client(runner).with_running(ensure_running: false) { :result }

    assert_equal :result, result
    refute runner.calls.any? { |call| call[:args].include?("up") }
    assert runner.calls.any? { |call| call[:args].include?("down") }
  end

  def test_with_running_preserves_a_block_exception_when_cleanup_fails
    original_error = RuntimeError.new("block failed")
    cleanup_error =
      LocalDevelopmentGateway::DockerError.new(
        %w[docker compose],
        "cleanup failed"
      )
    runner = FakeRunner.new(compose_error: cleanup_error)

    error =
      assert_raises(RuntimeError) do
        client(runner).with_running { raise original_error }
      end

    assert_same original_error, error
    assert runner.calls.any? { |call| call[:args].include?("down") }
  end

  def test_with_running_cleans_up_when_startup_fails
    startup_error =
      LocalDevelopmentGateway::DockerError.new(
        %w[docker compose],
        "startup failed"
      )
    runner = FakeRunner.new(gateway_ids: "", startup_error: startup_error)

    error =
      assert_raises(LocalDevelopmentGateway::DockerError) do
        client(runner).with_running { flunk "block should not run" }
      end

    assert_same startup_error, error
    assert runner.calls.any? { |call| call[:args].include?("down") }
  end

  def test_with_running_preserves_a_gateway_used_by_another_project
    runner = FakeRunner.new(attached: <<~CONTAINERS)
        gateway-id\tlocal-gateway\tgateway\ttrue
        consumer-id\tconsumer-project\tweb\t
      CONTAINERS

    assert_equal :result, client(runner).with_running { :result }
    refute runner.calls.any? { |call| call[:args].include?("down") }
  end

  def test_module_with_running_delegates_to_a_single_client
    fake_client = Object.new
    observed_ensure_running = nil
    fake_client.define_singleton_method(
      :with_running
    ) do |ensure_running: true, &block|
      observed_ensure_running = ensure_running
      block.call
    end

    LocalDevelopmentGateway::Client.stub(:new, fake_client) do
      assert_equal :result,
                   LocalDevelopmentGateway.with_running(ensure_running: false) {
                     :result
                   }
    end

    refute observed_ensure_running
  end

  private

  def build_gem
    spec =
      Gem::Specification.load(
        File.expand_path("../local-development-gateway.gemspec", __dir__)
      )
    gem_path = File.join(Dir.mktmpdir, "local-development-gateway.gem")
    _stdout, stderr, status =
      Open3.capture3("gem", "build", spec.loaded_from, "--output", gem_path)
    raise stderr unless status.success?

    gem_path
  end

  def client(runner)
    LocalDevelopmentGateway::Client.new(
      runner: runner,
      timeout: 1,
      sleeper: ->(_seconds) {}
    )
  end
end
