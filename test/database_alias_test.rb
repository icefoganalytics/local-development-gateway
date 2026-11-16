# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "open3"
require "rbconfig"
require "local_development_gateway"

class DatabaseAliasTest < Minitest::Test
  def test_preserves_short_aliases_without_normalization
    assert_equal "my_project-DB_Trav-Com",
                 LocalDevelopmentGateway.database_alias(
                   project_name: "my_project",
                   service_name: "DB_Trav-Com"
                 )
    assert_equal "9project_-8Service_",
                 LocalDevelopmentGateway.database_alias(
                   project_name: "9project_",
                   service_name: "8Service_"
                 )
  end

  def test_preserves_exactly_63_byte_aliases
    { "db" => 60, "db_trav_com" => 51 }.each do |service_name, project_length|
      project_name = "a" * project_length
      full_alias = "#{project_name}-#{service_name}"

      assert_equal 63, full_alias.bytesize
      assert_equal full_alias,
                   LocalDevelopmentGateway.database_alias(
                     project_name: project_name,
                     service_name: service_name
                   )
    end
  end

  def test_shortens_64_byte_aliases_using_the_permanent_derivation
    { "db" => 61, "db_trav_com" => 52 }.each do |service_name, project_length|
      project_name = "a" * project_length
      full_alias = "#{project_name}-#{service_name}"
      suffix =
        Digest::SHA256.hexdigest("#{project_name}\0#{service_name}")[0, 24]
      alias_name =
        LocalDevelopmentGateway.database_alias(
          project_name: project_name,
          service_name: service_name
        )

      assert_equal 64, full_alias.bytesize
      assert_equal "#{full_alias[0, 38]}-#{suffix}", alias_name
      assert_equal 63, alias_name.bytesize
    end
  end

  def test_shortens_arbitrarily_long_service_names
    project_name = "project"
    service_name = "Service_" * 40
    full_alias = "#{project_name}-#{service_name}"
    suffix = Digest::SHA256.hexdigest("#{project_name}\0#{service_name}")[0, 24]
    alias_name =
      LocalDevelopmentGateway.database_alias(
        project_name: project_name,
        service_name: service_name
      )

    assert_equal "#{full_alias[0, 38]}-#{suffix}", alias_name
    assert_equal 63, alias_name.bytesize
    assert_match(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/, alias_name)
  end

  def test_repeats_the_same_alias_including_in_a_fresh_ruby_process
    project_name = "long-project_" * 8
    service_name = "Database_Service"
    alias_name =
      LocalDevelopmentGateway.database_alias(
        project_name: project_name,
        service_name: service_name
      )

    3.times do
      assert_equal alias_name,
                   LocalDevelopmentGateway.database_alias(
                     project_name: project_name,
                     service_name: service_name
                   )
    end

    output, error, status =
      Open3.capture3(
        RbConfig.ruby,
        "-I",
        File.expand_path("../lib", __dir__),
        "-rlocal_development_gateway",
        "-e",
        "print LocalDevelopmentGateway.database_alias(project_name: ARGV[0], service_name: ARGV[1])",
        project_name,
        service_name
      )

    assert status.success?, error
    assert_equal alias_name, output
  end

  def test_distinguishes_long_names_with_a_common_prefix
    common_prefix = "a" * 80
    first_alias =
      LocalDevelopmentGateway.database_alias(
        project_name: "#{common_prefix}one",
        service_name: "db"
      )
    second_alias =
      LocalDevelopmentGateway.database_alias(
        project_name: "#{common_prefix}two",
        service_name: "db"
      )

    assert_equal first_alias[0, 38], second_alias[0, 38]
    refute_equal first_alias, second_alias
  end

  def test_distinguishes_different_partitions_of_the_same_full_alias
    project_name = "a" * 64

    first_alias =
      LocalDevelopmentGateway.database_alias(
        project_name: project_name,
        service_name: "b-db"
      )
    second_alias =
      LocalDevelopmentGateway.database_alias(
        project_name: "#{project_name}-b",
        service_name: "db"
      )

    assert_equal first_alias[0, 38], second_alias[0, 38]
    refute_equal first_alias, second_alias
  end

  def test_rejects_invalid_project_names_instead_of_normalizing
    [
      nil,
      1,
      :project,
      "",
      "Project",
      "-project",
      "_project",
      "a.b",
      "a b",
      "a/b",
      "a\nb",
      "a\0b",
      "prójèct"
    ].each do |project_name|
      assert_raises(
        ArgumentError,
        "accepted project_name #{project_name.inspect}"
      ) do
        LocalDevelopmentGateway.database_alias(
          project_name: project_name,
          service_name: "db"
        )
      end
    end
  end

  def test_rejects_invalid_service_names_instead_of_normalizing
    [
      nil,
      1,
      :db,
      "",
      "-db",
      "_db",
      "db.name",
      "db name",
      "db/name",
      "db\n",
      "db\0",
      "déb"
    ].each do |service_name|
      assert_raises(
        ArgumentError,
        "accepted service_name #{service_name.inspect}"
      ) do
        LocalDevelopmentGateway.database_alias(
          project_name: "project",
          service_name: service_name
        )
      end
    end
  end

  def test_does_not_mutate_source_names
    ["project", "project" * 20].each do |original_project|
      project_name = original_project.dup
      service_name = "DB_Service".dup

      LocalDevelopmentGateway.database_alias(
        project_name: project_name,
        service_name: service_name
      )

      assert_equal original_project, project_name
      assert_equal "DB_Service", service_name
      refute project_name.frozen?
      refute service_name.frozen?
    end
  end
end
