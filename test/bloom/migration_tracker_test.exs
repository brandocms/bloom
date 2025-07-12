defmodule Bloom.MigrationTrackerTest do
  use ExUnit.Case, async: true

  alias Bloom.MigrationTracker

  setup do
    # Configure test environment
    Application.put_env(:bloom, :ecto_repos, [])
    Application.put_env(:bloom, :app_root, "test/tmp/#{:erlang.unique_integer()}")

    :ok
  end

  describe "check_pending_migrations/0" do
    test "returns empty map when no repos configured" do
      Application.put_env(:bloom, :ecto_repos, [])

      result = MigrationTracker.check_pending_migrations()
      assert result == %{}
    end
  end

  describe "run_pending_migrations/0" do
    test "returns ok with empty map when no pending migrations" do
      Application.put_env(:bloom, :ecto_repos, [])

      assert {:ok, %{}} = MigrationTracker.run_pending_migrations()
    end
  end

  describe "rollback_deployment_migrations/1" do
    test "returns ok when no migration info found" do
      # Initialize metadata first so load_metadata succeeds but has no migration info
      Bloom.Metadata.init_metadata_storage()

      version = "1.2.3"

      result = MigrationTracker.rollback_deployment_migrations(version)
      assert {:ok, :no_migrations} = result
    end
  end

  describe "save_migration_info/2" do
    test "saves migration information" do
      # Initialize metadata first
      Bloom.Metadata.init_metadata_storage()

      # Configure empty repos so get_current_migration_versions returns empty map
      Application.put_env(:bloom, :ecto_repos, [])

      version = "1.2.3"
      executed_migrations = %{TestRepo => [1, 2, 3]}

      result = MigrationTracker.save_migration_info(version, executed_migrations)
      assert :ok = result
    end
  end
end
