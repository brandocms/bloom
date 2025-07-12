defmodule Bloom.DatabaseBackupTest do
  # MUST be false - modifies Application environment
  use ExUnit.Case, async: false

  alias Bloom.DatabaseBackup

  # Mock backend for testing
  defmodule TestBackend do
    @behaviour Bloom.DatabaseBackup.Backend

    def create_backup(_version) do
      {:error, :mock_backend_failure}
    end

    def restore_backup(_backup_info) do
      {:error, :mock_restore_failure}
    end

    def list_backups do
      {:ok, []}
    end

    def delete_backup(_backup_info) do
      {:error, :mock_delete_failure}
    end
  end

  setup do
    # Store original configuration
    original_app_root = Application.get_env(:bloom, :app_root)
    original_backup_enabled = Application.get_env(:bloom, :database_backup_enabled)
    original_backup_backend = Application.get_env(:bloom, :database_backup_backend)

    # Create unique test directory
    test_dir = "test/tmp/db_backup_#{:erlang.unique_integer()}"

    # Configure test environment
    Application.put_env(:bloom, :app_root, test_dir)

    on_exit(fn ->
      # Clean up test directory
      File.rm_rf(test_dir)
      # Restore original configuration
      restore_env(:bloom, :app_root, original_app_root)
      restore_env(:bloom, :database_backup_enabled, original_backup_enabled)
      restore_env(:bloom, :database_backup_backend, original_backup_backend)
    end)

    :ok
  end

  # Helper to restore environment variables
  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  describe "create_backup/1" do
    test "returns ok when backup is disabled" do
      Application.put_env(:bloom, :database_backup_enabled, false)

      result = DatabaseBackup.create_backup("1.2.3")
      assert {:ok, :backup_disabled} = result
    end

    test "returns error when backup backend fails" do
      Application.put_env(:bloom, :database_backup_enabled, true)
      Application.put_env(:bloom, :database_backup_backend, Bloom.DatabaseBackupTest.TestBackend)

      # Mock backend will return an error
      result = DatabaseBackup.create_backup("1.2.3")
      assert {:error, {:backup_required, :mock_backend_failure}} = result
    end
  end

  describe "restore_backup/1" do
    test "returns error when no backup found" do
      version = "1.2.3"

      result = DatabaseBackup.restore_backup(version)
      assert {:error, :file_not_found} = result
    end
  end

  describe "cleanup_old_backups/0" do
    test "returns ok when backup is disabled" do
      Application.put_env(:bloom, :database_backup_enabled, false)

      result = DatabaseBackup.cleanup_old_backups()
      assert :ok = result
    end
  end
end
