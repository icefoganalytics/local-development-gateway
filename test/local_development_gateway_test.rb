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

    def initialize(network_labels: "local-gateway\tlocal-gateway\n", gateway_ids: "gateway-id\n", health: "healthy\n", attached: "gateway-id\tlocal-gateway\tgateway\ttrue\n")
      @network_labels = network_labels
      @gateway_ids = gateway_ids
      @health = health
      @attached = attached
      @calls = []
    end

    def call(*args, capture: true)
      @calls << { args: args, capture: capture }
      case args.first
      when "network"
        raise LocalDevelopmentGateway::DockerError.new(args, "missing") if @network_labels.nil?

        @network_labels
      when "ps"
        args.include?("--format") ? @attached : @gateway_ids
      when "inspect"
        @health
      when "compose"
        @gateway_ids = "gateway-id\n" if args.include?("up")
        ""
      end
    end
  end

  def test_assets_are_packaged_with_the_gem
    spec = Gem::Specification.load(File.expand_path("../local-development-gateway.gemspec", __dir__))
    gem_path = File.join(Dir.mktmpdir, "local-development-gateway.gem")
    _stdout, stderr, status = Open3.capture3("gem", "build", spec.loaded_from, "--output", gem_path)

    assert status.success?, stderr
    assert_includes Gem::Package.new(gem_path).contents, "config/traefik.yml"
    assert_includes Gem::Package.new(gem_path).contents, "docker-compose.yml"
  end

  def test_installed_gem_resolves_packaged_asset_paths
    gem_path = build_gem
    gem_home = Dir.mktmpdir
    _stdout, stderr, status = Open3.capture3(
      "gem", "install", "--local", "--no-document", "--install-dir", gem_home, gem_path,
    )
    assert status.success?, stderr
    script = <<~RUBY
      require "local_development_gateway"
      puts LocalDevelopmentGateway::COMPOSE_FILE
      puts LocalDevelopmentGateway::TRAEFIK_CONFIG_FILE
    RUBY

    stdout, stderr, status = Open3.capture3(
      { "GEM_HOME" => gem_home, "GEM_PATH" => gem_home },
      RbConfig.ruby,
      "-e",
      script,
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

  def test_starts_and_waits_for_a_ready_gateway
    runner = FakeRunner.new(gateway_ids: "")

    assert_equal :started, client(runner).ensure_running
    assert runner.calls.any? { |call| call[:args].include?("up") }
  end

  def test_preserves_gateway_when_an_unrelated_attached_container_exists
    runner = FakeRunner.new(
      attached: <<~CONTAINERS,
        gateway-id\tlocal-gateway\tgateway\ttrue
        consumer-id\tconsumer-project\tweb\t
      CONTAINERS
    )

    assert_equal :in_use, client(runner).stop_if_unused
    refute runner.calls.any? { |call| call[:args].include?("down") }
  end

  def test_stops_the_last_gateway_when_only_gateway_container_remains
    runner = FakeRunner.new

    assert_equal :stopped, client(runner).stop_if_unused
    assert runner.calls.any? { |call| call[:args].include?("down") }
  end

  private

  def build_gem
    spec = Gem::Specification.load(File.expand_path("../local-development-gateway.gemspec", __dir__))
    gem_path = File.join(Dir.mktmpdir, "local-development-gateway.gem")
    _stdout, stderr, status = Open3.capture3("gem", "build", spec.loaded_from, "--output", gem_path)
    raise stderr unless status.success?

    gem_path
  end

  def client(runner)
    LocalDevelopmentGateway::Client.new(runner: runner, timeout: 1, sleeper: ->(_seconds) {})
  end
end
