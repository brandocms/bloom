defmodule Bloom.DatabaseBackup.Backend do
  @moduledoc """
  Behaviour for database backup backends.

  This defines the interface that all backup backends must implement
  to support different database systems (PostgreSQL, MySQL, etc.).
  """

  @doc """
  Create a backup for the given release version.

  Returns {:ok, backup_info} where backup_info is a map containing:
  - path: Full path to the backup file
  - filename: Name of the backup file
  - size_bytes: Size of the backup in bytes
  - created_at: DateTime when backup was created
  - version: Release version this backup is for
  - backend: Module that created this backup

  Returns {:error, reason} on failure.
  """
  @callback create_backup(version :: String.t()) ::
              {:ok, map()} | {:error, any()}

  @doc """
  Restore database from backup.

  Takes backup_info map returned from create_backup/1.
  Returns :ok on success, {:error, reason} on failure.
  """
  @callback restore_backup(backup_info :: map()) ::
              :ok | {:error, any()}

  @doc """
  List all available backups.

  Returns {:ok, [backup_info]} where each backup_info follows
  the same format as create_backup/1.
  """
  @callback list_backups() ::
              {:ok, [map()]} | {:error, any()}

  @doc """
  Delete a specific backup.

  Takes backup_info map and removes the backup file.
  Returns :ok on success, {:error, reason} on failure.
  """
  @callback delete_backup(backup_info :: map()) ::
              :ok | {:error, any()}
end
