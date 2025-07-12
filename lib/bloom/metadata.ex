defmodule Bloom.Metadata do
  @moduledoc """
  Release metadata management for tracking deployment history and rollback targets.

  This module provides persistence for release information, deployment timestamps,
  and rollback history to support safe release operations.
  """

  require Logger

  @metadata_file "priv/release_metadata.json"

  @doc """
  Save release information after a successful deployment.

  Records the deployment timestamp, previous version, and other
  metadata needed for rollback operations.
  """
  def save_release_info(version, info \\ %{}) when is_binary(version) do
    metadata = %{
      version: version,
      deployed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      deployed_by: System.get_env("USER") || "unknown",
      node: Node.self(),
      previous_version: get_current_version(),
      info: info
    }

    case add_to_history(metadata) do
      :ok ->
        Logger.info("Saved release metadata for version #{version}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to save release metadata: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get the target version for rollback operations.

  Returns the most recent previous version that can be safely
  rolled back to.
  """
  def get_rollback_target do
    case load_metadata() do
      {:ok, metadata} ->
        case find_rollback_target(metadata) do
          nil ->
            Logger.warning("No rollback target found in metadata")
            {:error, :no_rollback_target}

          version ->
            Logger.info("Rollback target: #{version}")
            {:ok, version}
        end

      {:error, reason} ->
        Logger.error("Could not load metadata for rollback target: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get the complete deployment history.

  Returns a list of all recorded deployments, most recent first.
  """
  def get_deployment_history(limit \\ 50) do
    case load_metadata() do
      {:ok, %{"deployments" => deployments}} ->
        limited_deployments =
          deployments
          |> Enum.take(limit)

        {:ok, limited_deployments}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get information about a specific release version.
  """
  def get_release_info(version) when is_binary(version) do
    case load_metadata() do
      {:ok, %{"deployments" => deployments}} ->
        case Enum.find(deployments, fn dep -> dep["version"] == version end) do
          nil -> {:error, :version_not_found}
          deployment -> {:ok, deployment}
        end

      {:ok, _} ->
        {:error, :version_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Save migration information for a deployment.
  """
  def save_migration_info(version, migration_data) do
    case load_metadata() do
      {:ok, metadata} ->
        migrations = Map.get(metadata, "migrations", %{})
        new_migrations = Map.put(migrations, version, migration_data)
        new_metadata = Map.put(metadata, "migrations", new_migrations)

        case save_metadata(new_metadata) do
          :ok ->
            Logger.info("Saved migration info for version #{version}")
            :ok

          {:error, reason} ->
            Logger.error("Failed to save migration info: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get migration information for a deployment.
  """
  def get_migration_info(version) do
    case load_metadata() do
      {:ok, metadata} ->
        migrations = Map.get(metadata, "migrations", %{})

        case Map.get(migrations, version) do
          nil -> {:error, :no_migration_info}
          info -> {:ok, info}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Save database backup information for a deployment.
  """
  def save_backup_info(version, backup_data) do
    case load_metadata() do
      {:ok, metadata} ->
        backups = Map.get(metadata, "backups", %{})
        new_backups = Map.put(backups, version, backup_data)
        new_metadata = Map.put(metadata, "backups", new_backups)

        case save_metadata(new_metadata) do
          :ok ->
            Logger.info("Saved backup info for version #{version}")
            :ok

          {:error, reason} ->
            Logger.error("Failed to save backup info: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get database backup information for a deployment.
  """
  def get_backup_info(version) do
    case load_metadata() do
      {:ok, metadata} ->
        backups = Map.get(metadata, "backups", %{})

        case Map.get(backups, version) do
          nil -> {:error, :no_backup}
          info -> {:ok, info}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Clean up old deployment records, keeping only the specified number.
  """
  def cleanup_old_records(keep_count \\ 50) when is_integer(keep_count) and keep_count > 0 do
    case load_metadata() do
      {:ok, metadata} ->
        deployments = Map.get(metadata, "deployments", [])

        if length(deployments) > keep_count do
          kept_deployments = Enum.take(deployments, keep_count)
          new_metadata = Map.put(metadata, "deployments", kept_deployments)

          case save_metadata(new_metadata) do
            :ok ->
              removed_count = length(deployments) - keep_count
              Logger.info("Cleaned up #{removed_count} old deployment records")
              :ok

            {:error, reason} ->
              {:error, reason}
          end
        else
          # Nothing to clean up
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Initialize metadata storage if it doesn't exist.
  """
  def init_metadata_storage do
    ensure_priv_dir()

    if not File.exists?(metadata_file_path()) do
      initial_metadata = %{
        "version" => "1.0",
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "deployments" => []
      }

      case save_metadata(initial_metadata) do
        :ok ->
          Logger.info("Initialized release metadata storage")
          :ok

        {:error, reason} ->
          Logger.error("Failed to initialize metadata storage: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  end

  # Private Implementation

  defp add_to_history(deployment_metadata) do
    case load_metadata() do
      {:ok, metadata} ->
        deployments = Map.get(metadata, "deployments", [])
        new_deployments = [deployment_metadata | deployments]
        new_metadata = Map.put(metadata, "deployments", new_deployments)
        save_metadata(new_metadata)

      {:error, :file_not_found} ->
        # Initialize with this deployment
        initial_metadata = %{
          "version" => "1.0",
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "deployments" => [deployment_metadata]
        }

        save_metadata(initial_metadata)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_rollback_target(metadata) do
    deployments = Map.get(metadata, "deployments", [])

    case deployments do
      [_current | [previous | _]] ->
        # Return the previous deployment version
        previous["version"]

      [current] ->
        # Only one deployment, check if it has a previous_version recorded
        current["previous_version"]

      [] ->
        nil
    end
  end

  defp load_metadata do
    path = metadata_file_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, metadata} -> {:ok, metadata}
            {:error, reason} -> {:error, {:json_decode_error, reason}}
          end

        {:error, reason} ->
          {:error, {:file_read_error, reason}}
      end
    else
      {:error, :file_not_found}
    end
  end

  defp save_metadata(metadata) do
    ensure_priv_dir()
    path = metadata_file_path()

    case Jason.encode(metadata, pretty: true) do
      {:ok, json} ->
        case File.write(path, json) do
          :ok -> :ok
          {:error, reason} -> {:error, {:file_write_error, reason}}
        end

      {:error, reason} ->
        {:error, {:json_encode_error, reason}}
    end
  end

  defp metadata_file_path do
    Path.join([get_app_root(), @metadata_file])
  end

  defp ensure_priv_dir do
    priv_dir = Path.join([get_app_root(), "priv"])
    File.mkdir_p(priv_dir)
  end

  defp get_app_root do
    # Try to get the application directory
    case Application.get_env(:bloom, :app_root) do
      nil ->
        # Fallback to current working directory
        File.cwd!()

      app_root ->
        app_root
    end
  end

  defp get_current_version do
    try do
      case Bloom.ReleaseManager.current_release() do
        {:ok, %{version: version}} -> version
        _ -> nil
      end
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end
end
