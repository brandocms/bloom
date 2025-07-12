defmodule Bloom.DatabaseBackup.Postgres do
  @moduledoc """
  PostgreSQL database backup backend using pg_dump and pg_restore.

  This backend creates SQL dump files that can be restored using psql or pg_restore.
  """

  @behaviour Bloom.DatabaseBackup.Backend

  require Logger

  @impl true
  def create_backup(version) do
    backup_dir = get_backup_directory()
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    filename = "#{version}_#{timestamp}.sql"
    backup_path = Path.join(backup_dir, filename)

    # Ensure backup directory exists
    File.mkdir_p!(backup_dir)

    case run_pg_dump(backup_path) do
      :ok ->
        backup_info = %{
          path: backup_path,
          filename: filename,
          size_bytes: File.stat!(backup_path).size,
          created_at: DateTime.utc_now(),
          version: version,
          backend: __MODULE__
        }

        {:ok, backup_info}

      {:error, reason} ->
        # Clean up failed backup file if it exists
        File.rm(backup_path)
        {:error, reason}
    end
  end

  @impl true
  def restore_backup(backup_info) do
    if File.exists?(backup_info.path) do
      case run_restore(backup_info.path) do
        :ok ->
          Logger.info("PostgreSQL backup restored from #{backup_info.path}")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :backup_file_not_found}
    end
  end

  @impl true
  def list_backups do
    backup_dir = get_backup_directory()

    if File.exists?(backup_dir) do
      backups =
        backup_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".sql"))
        |> Enum.map(&parse_backup_filename/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

      {:ok, backups}
    else
      {:ok, []}
    end
  end

  @impl true
  def delete_backup(backup_info) do
    case File.rm(backup_info.path) do
      :ok ->
        Logger.info("Deleted PostgreSQL backup: #{backup_info.path}")
        :ok

      {:error, reason} ->
        {:error, {:delete_failed, reason}}
    end
  end

  # Private Implementation

  defp get_backup_directory do
    Application.get_env(:bloom, :database_backup_directory, "/tmp/bloom_backups")
  end

  defp run_pg_dump(backup_path) do
    _timeout = Application.get_env(:bloom, :database_backup_timeout_ms, 300_000)

    # Get database connection info
    case get_database_config() do
      {:ok, config} ->
        args = build_pg_dump_args(config, backup_path)
        env = build_pg_env(config)

        Logger.info("Running pg_dump to #{backup_path}")

        case System.cmd("pg_dump", args, env: env, stderr_to_stdout: true) do
          {_output, 0} ->
            Logger.debug("pg_dump completed successfully")
            :ok

          {output, exit_code} ->
            Logger.error("pg_dump failed with exit code #{exit_code}: #{output}")
            {:error, {:pg_dump_failed, exit_code, output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("pg_dump exception: #{inspect(error)}")
      {:error, {:pg_dump_exception, error}}
  end

  defp run_restore(backup_path) do
    _timeout = Application.get_env(:bloom, :database_backup_timeout_ms, 300_000)

    case get_database_config() do
      {:ok, config} ->
        args = build_restore_args(config, backup_path)
        env = build_pg_env(config)

        Logger.info("Restoring PostgreSQL backup from #{backup_path}")

        case System.cmd("psql", args, env: env, stderr_to_stdout: true) do
          {_output, 0} ->
            Logger.debug("PostgreSQL restore completed successfully")
            :ok

          {output, exit_code} ->
            Logger.error("PostgreSQL restore failed with exit code #{exit_code}: #{output}")
            {:error, {:restore_failed, exit_code, output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("PostgreSQL restore exception: #{inspect(error)}")
      {:error, {:restore_exception, error}}
  end

  defp get_database_config do
    # Try to get config from Ecto repo
    case get_configured_repos() do
      [repo | _] ->
        config = repo.config()

        database_config = %{
          hostname: Keyword.get(config, :hostname, "localhost"),
          port: Keyword.get(config, :port, 5432),
          database: Keyword.fetch!(config, :database),
          username: Keyword.get(config, :username),
          password: Keyword.get(config, :password)
        }

        {:ok, database_config}

      [] ->
        {:error, :no_repo_configured}
    end
  rescue
    error ->
      {:error, {:config_error, error}}
  end

  defp get_configured_repos do
    case Application.get_env(:bloom, :ecto_repos) do
      repos when is_list(repos) -> repos
      repo when is_atom(repo) -> [repo]
      nil -> []
    end
  end

  defp build_pg_dump_args(config, backup_path) do
    args = [
      "--host",
      config.hostname,
      "--port",
      to_string(config.port),
      "--dbname",
      config.database,
      "--file",
      backup_path,
      "--verbose",
      "--no-password",
      "--clean",
      "--if-exists"
    ]

    case config.username do
      nil -> args
      username -> ["--username", username | args]
    end
  end

  defp build_restore_args(config, backup_path) do
    args = [
      "--host",
      config.hostname,
      "--port",
      to_string(config.port),
      "--dbname",
      config.database,
      "--file",
      backup_path,
      "--no-password",
      "--quiet"
    ]

    case config.username do
      nil -> args
      username -> ["--username", username | args]
    end
  end

  defp build_pg_env(config) do
    env = []

    case config.password do
      nil -> env
      password -> [{"PGPASSWORD", password} | env]
    end
  end

  defp parse_backup_filename(filename) do
    # Parse filename like "1.2.3_20231201T120000Z.sql"
    case Regex.run(~r/^(.+)_(\d{8}T\d{6}Z)\.sql$/, filename) do
      [_, version, timestamp_str] ->
        case DateTime.from_iso8601(timestamp_str) do
          {:ok, created_at, _} ->
            backup_path = Path.join(get_backup_directory(), filename)

            %{
              path: backup_path,
              filename: filename,
              version: version,
              created_at: created_at,
              size_bytes: get_file_size(backup_path),
              backend: __MODULE__
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp get_file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
