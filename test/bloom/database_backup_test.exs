defmodule Bloom.DatabaseBackupTest do
  use ExUnit.Case, async: true

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
    # Configure test environment
    Application.put_env(:bloom, :app_root, "test/tmp/#{:erlang.unique_integer()}")

    :ok
  end

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
