# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"

module LocalDevelopmentGateway
  # Coordinates this user's clients of one Docker daemon. Operation locks live
  # beyond the coordinator lock, so project commands never serialize each other.
  class Lifecycle
    def initialize(
      runner:,
      directory: File.join(
        Dir.home,
        ".local",
        "state",
        "local-development-gateway"
      )
    )
      @runner = runner
      @directory = directory
    end

    def synchronize
      daemon_id = @runner.call("info", "--format", "{{.ID}}").strip
      raise Error, "Docker daemon identity is unavailable" if daemon_id.empty?

      private_directory(@directory)
      directory = File.join(@directory, Digest::SHA256.hexdigest(daemon_id))
      private_directory(directory)
      open_file(File.join(directory, "coordinator")) do |lock|
        unless lock.flock(File::LOCK_EX)
          raise Error, "Lifecycle coordination lock unavailable"
        end

        yield directory
      end
    rescue SystemCallError, IOError, NotImplementedError => error
      raise Error, "Lifecycle coordination unavailable: #{error.message}"
    end

    def register_operation(directory)
      locked = false
      path = File.join(directory, "operation-#{SecureRandom.hex(16)}")
      file = open_file(path, exclusive: true)
      locked = file.flock(File::LOCK_EX | File::LOCK_NB)
      raise Error, "Lifecycle operation lock unavailable" unless locked

      file
    ensure
      file.close if file && !locked
    end

    def release_operation(operation)
      File.unlink(operation.path)
    ensure
      operation.close
    end

    def retained?(directory)
      pending = false
      Dir
        .glob(File.join(directory, "operation-*"))
        .each do |path|
          open_file(path) do |file|
            if file.flock(File::LOCK_EX | File::LOCK_NB)
              File.unlink(path)
            else
              pending = true
            end
          end
        end
      pending || !Dir.glob(File.join(directory, "hold-*")).empty?
    end

    def hold(directory, name)
      open_file(hold_path(directory, name)) { |_file| nil }
      :held
    end

    def release(directory, name)
      path = hold_path(directory, name)
      File.unlink(path)
    rescue Errno::ENOENT
      nil
    end

    def validate_name(name)
      unless name.is_a?(String) &&
               /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/.match?(name)
        raise Error,
              "Hold name must start with a letter or digit and contain " \
                "1–64 letters, digits, dots, underscores or hyphens"
      end
    end

    private

    def hold_path(directory, name)
      validate_name(name)
      File.join(directory, "hold-#{name}")
    end

    def private_directory(path)
      FileUtils.mkdir_p(path, mode: 0o700)
      stat = File.lstat(path)
      unless stat.directory? && stat.uid == Process.uid &&
               (stat.mode & 0o077).zero?
        raise Error,
              "Lifecycle directory must be private and owned by this user: #{path}"
      end
    end

    def open_file(path, exclusive: false)
      flags = File::RDWR | File::CREAT | File::NOFOLLOW
      flags |= File::EXCL if exclusive
      file = File.open(path, flags, 0o600)
      file.close_on_exec = true
      stat = file.stat
      unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
        file.close
        raise Error, "Unsafe lifecycle state file: #{path}"
      end
      return file unless block_given?

      begin
        yield file
      ensure
        file.close unless file.closed?
      end
    end
  end
end
