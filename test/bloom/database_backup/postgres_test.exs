defmodule Bloom.DatabaseBackup.PostgresTest do
  use ExUnit.Case, async: true

  alias Bloom.DatabaseBackup.Postgres

  setup do
    # Configure test environment  
    Application.put_env(:bloom, :ecto_repos, [])

    Application.put_env(
      :bloom,
      :database_backup_directory,
      "test/tmp/#{:erlang.unique_integer()}"
    )

    :ok
  end

  describe "create_backup/1" do
    test "returns error when no repo configured" do
      Application.put_env(:bloom, :ecto_repos, [])

      result = Postgres.create_backup("1.2.3")
      assert {:error, :no_repo_configured} = result
    end
  end

  describe "list_backups/0" do
    test "returns empty list when backup directory doesn't exist" do
      result = Postgres.list_backups()
      assert {:ok, []} = result
    end

    test "returns empty list when no backup files exist" do
      backup_dir = Application.get_env(:bloom, :database_backup_directory)
      File.mkdir_p!(backup_dir)

      result = Postgres.list_backups()
      assert {:ok, []} = result
    end
  end

  describe "delete_backup/1" do
    test "returns error when backup file doesn't exist" do
      backup_info = %{path: "/nonexistent/file.sql"}

      result = Postgres.delete_backup(backup_info)
      assert {:error, {:delete_failed, :enoent}} = result
    end
  end

  describe "restore_backup/1" do
    test "returns error when backup file doesn't exist" do
      backup_info = %{path: "/nonexistent/file.sql"}

      result = Postgres.restore_backup(backup_info)
      assert {:error, :backup_file_not_found} = result
    end
  end
end
