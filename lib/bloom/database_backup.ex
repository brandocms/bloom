defmodule Bloom.DatabaseBackup do
  @moduledoc """
  Database backup and restore functionality for release rollbacks.

  This module provides pluggable backends for creating and restoring
  database backups before risky deployment operations.
  """

  require Logger

  @doc """
  Create a backup before a deployment.

  Returns {:ok, backup_info} on success, where backup_info contains
  metadata about the created backup.
  """
  def create_backup(version) do
    if backup_enabled?() do
      Logger.info("Creating database backup for deployment #{version}")

      case get_backup_backend().create_backup(version) do
        {:ok, backup_info} ->
          # Save backup metadata
          case save_backup_metadata(version, backup_info) do
            :ok ->
              Logger.info("Database backup created successfully: #{backup_info.path}")
              {:ok, backup_info}

            {:error, reason} ->
              Logger.warning("Backup created but metadata save failed: #{inspect(reason)}")
              {:ok, backup_info}
          end

        {:error, reason} ->
          Logger.error("Database backup failed: #{inspect(reason)}")
          handle_backup_failure(reason)
      end
    else
      Logger.info("Database backup disabled, skipping")
      {:ok, :backup_disabled}
    end
  end

  @doc """
  Restore database from backup for a specific deployment version.
  """
  def restore_backup(version) do
    Logger.info("Restoring database backup for version #{version}")

    case get_backup_info(version) do
      {:ok, backup_info} ->
        case get_backup_backend().restore_backup(backup_info) do
          :ok ->
            Logger.info("Database backup restored successfully from #{backup_info.path}")
            :ok

          {:error, reason} ->
            Logger.error("Database restore failed: #{inspect(reason)}")
            {:error, {:restore_failed, reason}}
        end

      {:error, :no_backup} ->
        Logger.error("No backup found for version #{version}")
        {:error, :no_backup_available}

      {:error, reason} ->
        Logger.error("Could not get backup info: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Clean up old backups based on retention policy.
  """
  def cleanup_old_backups do
    if backup_enabled?() do
      retention_count = Application.get_env(:bloom, :database_backup_retention_count, 5)

      case get_backup_backend().list_backups() do
        {:ok, backups} ->
          backups_to_delete =
            backups
            |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
            |> Enum.drop(retention_count)

          Enum.each(backups_to_delete, fn backup ->
            case get_backup_backend().delete_backup(backup) do
              :ok ->
                Logger.info("Deleted old backup: #{backup.path}")

              {:error, reason} ->
                Logger.warning("Failed to delete backup #{backup.path}: #{inspect(reason)}")
            end
          end)

          :ok

        {:error, reason} ->
          Logger.warning("Could not list backups for cleanup: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  end

  # Private Implementation

  defp backup_enabled? do
    Application.get_env(:bloom, :database_backup_enabled, false)
  end

  defp get_backup_backend do
    backend = Application.get_env(:bloom, :database_backup_backend, Bloom.DatabaseBackup.Postgres)

    # Ensure backend module is loaded
    Code.ensure_loaded!(backend)
    backend
  end

  defp handle_backup_failure(reason) do
    # Check if we should fail deployment on backup failure
    case Application.get_env(:bloom, :database_backup_required, true) do
      true ->
        {:error, {:backup_required, reason}}

      false ->
        Logger.warning("Backup failed but continuing deployment as backup is not required")
        {:ok, :backup_failed}
    end
  end

  defp save_backup_metadata(version, backup_info) do
    metadata = %{
      version: version,
      backup_info: backup_info,
      created_at: DateTime.utc_now()
    }

    Bloom.Metadata.save_backup_info(version, metadata)
  end

  defp get_backup_info(version) do
    case Bloom.Metadata.get_backup_info(version) do
      {:ok, metadata} ->
        {:ok, metadata.backup_info}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
