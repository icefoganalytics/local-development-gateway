# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "tmpdir"
require_relative "../lib/local_development_gateway"

class HostAgentTest < Minitest::Test
  class FakeRunner
    def call(*args, **)
      case args.first
      when "ps"
        <<~CONTAINERS
          first-id\tdb.issue-567.wrap.localhost\t1433
          second-id\tdb.wrapx-416.wrap.localhost\t1433
        CONTAINERS
      when "inspect"
        args.last == "first-id" ? "172.20.0.2\n" : "172.20.0.3\n"
      end
    end
  end

  def test_discovers_labelled_tcp_routes
    routes =
      LocalDevelopmentGateway::HostAgent::DockerRoutes.new(
        runner: FakeRunner.new
      ).call

    assert_equal(
      [
        ["db.issue-567.wrap.localhost", 1433, "172.20.0.2"],
        ["db.wrapx-416.wrap.localhost", 1433, "172.20.0.3"]
      ],
      routes.map { |route| [route.hostname, route.port, route.target_address] }
    )
  end

  def test_allocates_stable_loopback_addresses_and_reconciles_hosts
    with_registry do |registry, hosts_path|
      first = route("db.issue-567.wrap.localhost", "172.20.0.2")
      second = route("db.wrapx-416.wrap.localhost", "172.20.0.3")

      assigned = registry.reconcile([first, second])
      repeated = registry.reconcile([first, second])

      assert_equal assigned.map(&:address), repeated.map(&:address)
      refute_equal assigned.first.address, assigned.last.address
      assert_equal(<<~HOSTS, File.read(hosts_path))
          127.0.0.1 localhost

          # BEGIN local-development-gateway
          #{assigned.first.address} db.issue-567.wrap.localhost
          #{assigned.last.address} db.wrapx-416.wrap.localhost
          # END local-development-gateway
        HOSTS
    end
  end

  def test_removes_stopped_routes_without_touching_other_host_entries
    with_registry do |registry, hosts_path|
      registry.reconcile([route("db.issue-567.wrap.localhost", "172.20.0.2")])

      registry.reconcile([])

      assert_equal(<<~HOSTS, File.read(hosts_path))
          127.0.0.1 localhost

          # BEGIN local-development-gateway
          # END local-development-gateway
        HOSTS
    end
  end

  def test_rejects_non_localhost_routes
    with_registry do |registry, _hosts_path|
      error =
        assert_raises(LocalDevelopmentGateway::Error) do
          registry.reconcile([route("db.issue-567.example.com", "172.20.0.2")])
        end

      assert_equal "Invalid local TCP hostname: db.issue-567.example.com",
                   error.message
    end
  end

  def test_proxies_same_port_from_worktree_loopback_address
    target = TCPServer.new("127.0.0.1", 0)
    port = target.local_address.ip_port
    listener = LocalDevelopmentGateway::HostAgent::Listeners.new
    route =
      LocalDevelopmentGateway::HostAgent::Route.new(
        container_id: "db-id",
        hostname: "db.issue-567.wrap.localhost",
        port: port,
        target_address: "127.0.0.1",
        address: "127.77.0.1"
      )
    target_thread =
      Thread.new do
        connection = target.accept
        connection.write(connection.read(4))
        connection.close
      end
    listener.reconcile([route])
    client = TCPSocket.new(route.address, port)

    client.write("ping")

    assert_equal "ping", client.read(4)
  ensure
    client&.close
    listener&.reconcile([])
    target&.close
    target_thread&.join
  end

  def test_systemd_unit_runs_the_host_agent
    unit =
      LocalDevelopmentGateway::HostAgent::Installer.unit(
        executable: "/usr/local/bin/local-development-gateway",
        ruby: "/usr/bin/ruby"
      )

    assert_includes(
      unit,
      "ExecStart=/usr/bin/ruby /usr/local/bin/local-development-gateway host-agent"
    )
    assert_includes unit, "Requires=docker.service"
    assert_includes(
      unit,
      "ReadWritePaths=/etc/hosts /var/lib/local-development-gateway"
    )
  end

  def test_install_restarts_the_current_host_agent_version
    command = Object.new
    calls = []
    command.define_singleton_method(:call) { |*args| calls << args }

    Dir.mktmpdir do |directory|
      Process.stub(:uid, 0) do
        LocalDevelopmentGateway::HostAgent::Installer.install(
          executable: "/usr/local/bin/local-development-gateway",
          ruby: "/usr/bin/ruby",
          unit_path: File.join(directory, "host-agent.service"),
          command: command
        )
      end
    end

    assert_equal(
      [
        %w[systemctl daemon-reload],
        %w[systemctl enable local-development-gateway-host-agent.service],
        %w[systemctl restart local-development-gateway-host-agent.service]
      ],
      calls
    )
  end

  private

  def route(hostname, target_address)
    LocalDevelopmentGateway::HostAgent::Route.new(
      container_id: hostname,
      hostname: hostname,
      port: 14_333,
      target_address: target_address,
      address: nil
    )
  end

  def with_registry
    Dir.mktmpdir do |directory|
      hosts_path = File.join(directory, "hosts")
      File.write(hosts_path, "127.0.0.1 localhost\n")
      registry =
        LocalDevelopmentGateway::HostAgent::Registry.new(
          state_dir: File.join(directory, "state"),
          hosts_path: hosts_path
        )
      yield registry, hosts_path
    end
  end
end
