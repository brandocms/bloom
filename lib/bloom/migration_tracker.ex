defmodule Bloom.MigrationTracker do
  @moduledoc """
  Tracks database migrations during release operations.

  This module detects pending migrations before deployments,
  tracks which migrations are executed during deployment,
  and provides rollback capabilities for migrations.
  """

  require Logger

  @doc """
  Check if there are pending migrations for the configured Ecto repositories.

  Returns a map of repo => pending_migrations for each repository that has
  pending migrations, or an empty map if no migrations are pending.
  """
  def check_pending_migrations do
    repos = get_configured_repos()

    Enum.reduce(repos, %{}, fn repo, acc ->
      case get_pending_migrations(repo) do
        [] ->
          acc

        pending when is_list(pending) ->
          Map.put(acc, repo, pending)

        {:error, reason} ->
          Logger.warning("Could not check pending migrations for #{repo}: #{inspect(reason)}")
          acc
      end
    end)
  end

  @doc """
  Run pending migrations for all configured repositories.

  Returns {:ok, executed_migrations} on success, where executed_migrations
  is a map of repo => [migration_versions].
  """
  def run_pending_migrations do
    case check_pending_migrations() do
      empty when map_size(empty) == 0 ->
        Logger.info("No pending migrations found")
        {:ok, %{}}

      pending_by_repo ->
        Logger.info("Running pending migrations: #{inspect(Map.keys(pending_by_repo))}")
        execute_migrations(pending_by_repo)
    end
  end

  @doc """
  Rollback migrations to a specific version for a repository.

  This attempts to rollback migrations using Ecto's rollback functionality.
  """
  def rollback_migrations(repo, target_version) when is_integer(target_version) do
    Logger.info("Rolling back #{repo} migrations to version #{target_version}")

    try do
      case Ecto.Migrator.run(repo, :down, to: target_version) do
        [rolled_back_version] ->
          Logger.info("Successfully rolled back #{repo} to version #{rolled_back_version}")
          {:ok, rolled_back_version}

        [] ->
          Logger.info("No migrations to rollback for #{repo}")
          {:ok, target_version}

        versions when is_list(versions) ->
          Logger.info("Successfully rolled back #{repo} migrations: #{inspect(versions)}")
          {:ok, target_version}
      end
    rescue
      error ->
        Logger.error("Exception during rollback for #{repo}: #{inspect(error)}")
        {:error, {:rollback_exception, error}}
    end
  end

  @doc """
  Rollback all migrations that were executed during a specific deployment.

  Uses deployment metadata to determine which migrations to rollback.
  """
  def rollback_deployment_migrations(version) do
    case Bloom.Metadata.get_migration_info(version) do
      {:ok, migration_info} ->
        rollback_multiple_repos(migration_info)

      {:error, :no_migration_info} ->
        Logger.info("No migration info found for version #{version}, skipping migration rollback")
        {:ok, :no_migrations}

      {:error, :file_not_found} ->
        Logger.info("No migration info found for version #{version}, skipping migration rollback")
        {:ok, :no_migrations}

      {:error, reason} ->
        Logger.error("Could not get migration info for rollback: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Save migration information for a deployment version.

  This is called after migrations are run to track what was executed.
  """
  def save_migration_info(version, executed_migrations) do
    migration_data = %{
      version: version,
      executed_at: DateTime.utc_now(),
      migrations: executed_migrations,
      pre_migration_versions: get_current_migration_versions()
    }

    Bloom.Metadata.save_migration_info(version, migration_data)
  end

  # Private Implementation

  defp get_configured_repos do
    case Application.get_env(:bloom, :ecto_repos) do
      repos when is_list(repos) ->
        repos

      repo when is_atom(repo) ->
        [repo]

      nil ->
        Logger.warning("No ecto_repos configured for Bloom")
        []
    end
  end

  defp get_pending_migrations(repo) do
    try do
      # Get migration directory
      migration_dir = get_migration_directory(repo)

      # Get pending migrations
      Ecto.Migrator.migrations(repo, migration_dir)
      |> Enum.filter(fn {status, _version, _name} -> status == :down end)
      |> Enum.map(fn {_status, version, name} -> {version, name} end)
    rescue
      error ->
        {:error, {:migration_check_failed, error}}
    end
  end

  defp get_migration_directory(_repo) do
    # Try to get from configuration first
    case Application.get_env(:bloom, :migration_path) do
      nil ->
        # Fallback to Ecto default pattern
        _app_name = get_app_name()
        "priv/repo/migrations"

      path when is_binary(path) ->
        path
    end
  end

  defp get_app_name do
    case Application.get_env(:bloom, :app_name) do
      nil ->
        # Try to infer from the first repo
        case get_configured_repos() do
          [repo | _] ->
            repo
            |> Module.split()
            |> List.first()
            |> Macro.underscore()

          [] ->
            "app"
        end

      app_name when is_atom(app_name) ->
        Atom.to_string(app_name)

      app_name when is_binary(app_name) ->
        app_name
    end
  end

  defp execute_migrations(pending_by_repo) do
    results =
      Enum.map(pending_by_repo, fn {repo, pending} ->
        case run_migrations_for_repo(repo, pending) do
          {:ok, executed} ->
            {:ok, {repo, executed}}

          {:error, reason} ->
            {:error, {repo, reason}}
        end
      end)

    # Check if any failed
    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      nil ->
        # All succeeded
        executed =
          results
          |> Enum.map(fn {:ok, {repo, executed}} -> {repo, executed} end)
          |> Enum.into(%{})

        {:ok, executed}

      {:error, {repo, reason}} ->
        Logger.error("Migration failed for #{repo}: #{inspect(reason)}")
        {:error, {:migration_failed, repo, reason}}
    end
  end

  defp run_migrations_for_repo(repo, pending_migrations) do
    Logger.info("Running #{length(pending_migrations)} migrations for #{repo}")

    try do
      # Get versions before migration
      before_versions = get_current_versions(repo)

      # Run the migrations
      case Ecto.Migrator.run(repo, :up, all: true) do
        versions when is_list(versions) ->
          # Get versions after migration to see what was executed
          after_versions = get_current_versions(repo)
          executed = after_versions -- before_versions

          Logger.info("Successfully executed #{length(executed)} migrations for #{repo}")
          {:ok, executed}

        [] ->
          Logger.info("No migrations to run for #{repo}")
          {:ok, []}
      end
    rescue
      error ->
        {:error, {:migration_exception, error}}
    end
  end

  defp get_current_versions(repo) do
    try do
      Ecto.Migrator.migrated_versions(repo)
    rescue
      _ -> []
    end
  end

  defp get_current_migration_versions do
    repos = get_configured_repos()

    Enum.reduce(repos, %{}, fn repo, acc ->
      versions = get_current_versions(repo)
      Map.put(acc, repo, versions)
    end)
  end

  defp rollback_multiple_repos(migration_info) do
    results =
      Enum.map(migration_info.migrations, fn {repo, _executed_versions} ->
        # Find the version to rollback to (last version before these migrations)
        pre_versions = Map.get(migration_info.pre_migration_versions, repo, [])

        target_version =
          case pre_versions do
            # Rollback all migrations
            [] -> 0
            versions -> Enum.max(versions)
          end

        case rollback_migrations(repo, target_version) do
          {:ok, rolled_back_version} ->
            {:ok, {repo, rolled_back_version}}

          {:error, reason} ->
            {:error, {repo, reason}}
        end
      end)

    # Check if any failed
    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      nil ->
        rolled_back =
          results
          |> Enum.map(fn {:ok, {repo, version}} -> {repo, version} end)
          |> Enum.into(%{})

        {:ok, rolled_back}

      {:error, {repo, reason}} ->
        Logger.error("Migration rollback failed for #{repo}: #{inspect(reason)}")
        {:error, {:rollback_failed, repo, reason}}
    end
  end
end
