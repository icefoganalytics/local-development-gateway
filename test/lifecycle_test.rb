# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "timeout"
require "local_development_gateway"

class LifecycleTest < Minitest::Test
  class IdentityRunner
    def initialize(identity)
      @identity = identity
    end

    def call(*args)
      unless args == %w[info --format {{.ID}}]
        raise "Unexpected Docker command: #{args.inspect}"
      end

      @identity
    end
  end

  def setup
    @directory = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_locked_operation_retains_until_released_and_unlocked_stale_files_are_removed
    lifecycle = coordinator
    operation =
      lifecycle.synchronize do |directory|
        lifecycle.register_operation(directory)
      end

    lifecycle.synchronize do |directory|
      assert lifecycle.retained?(directory)
      lifecycle.release_operation(operation)
      refute lifecycle.retained?(directory)
      stale = lifecycle.register_operation(directory)
      stale.close
      refute lifecycle.retained?(directory)
      assert_empty Dir.glob(File.join(directory, "operation-*"))
    end
  ensure
    operation&.close unless operation&.closed?
  end

  def test_process_crash_releases_operation_lock_and_next_scan_recovers
    reader, writer = IO.pipe
    pid =
      fork do
        reader.close
        lifecycle = coordinator
        operation =
          lifecycle.synchronize do |directory|
            lifecycle.register_operation(directory)
          end
        writer.puts operation.path
        writer.close
        sleep
      end
    writer.close
    path = Timeout.timeout(5) { reader.gets&.strip }
    refute_nil path
    lifecycle = coordinator
    lifecycle.synchronize { |directory| assert lifecycle.retained?(directory) }

    Process.kill("KILL", pid)
    Process.wait(pid)
    pid = nil

    lifecycle.synchronize { |directory| refute lifecycle.retained?(directory) }
    refute File.exist?(path)
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
    if pid
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
  end

  def test_holds_are_per_daemon_and_do_not_use_daemon_id_as_a_path
    first = coordinator("daemon/one")
    second = coordinator("daemon/two")
    first.synchronize { |directory| first.hold(directory, "dbeaver") }

    second.synchronize { |directory| refute second.retained?(directory) }
    coordinator("daemon/one").synchronize do |directory|
      assert first.retained?(directory)
      first.release(directory, "dbeaver")
      refute first.retained?(directory)
    end
    assert_equal 2, Dir.children(@directory).length
  end

  def test_missing_daemon_identity_never_enters_coordinator
    assert_raises(LocalDevelopmentGateway::Error) do
      coordinator("").synchronize do
        flunk "must not proceed without daemon identity"
      end
    end
  end

  def test_shared_state_directory_is_rejected
    File.chmod(0o755, @directory)

    assert_raises(LocalDevelopmentGateway::Error) do
      coordinator.synchronize { flunk "must not use non-private state" }
    end
  ensure
    File.chmod(0o700, @directory)
  end

  def test_symlinked_coordinator_is_rejected_without_touching_target
    lifecycle = coordinator
    directory = lifecycle.synchronize { |path| path }
    File.unlink(File.join(directory, "coordinator"))
    target = File.join(@directory, "target")
    File.write(target, "untouched")
    File.symlink(target, File.join(directory, "coordinator"))

    assert_raises(LocalDevelopmentGateway::Error) do
      lifecycle.synchronize { flunk "must not use symlink lock" }
    end
    assert_equal "untouched", File.read(target)
  end

  private

  def coordinator(identity = "test-daemon")
    LocalDevelopmentGateway::Lifecycle.new(
      runner: IdentityRunner.new(identity),
      directory: @directory
    )
  end
end
