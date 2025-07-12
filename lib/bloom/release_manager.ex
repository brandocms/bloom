defmodule Bloom.ReleaseManager do
  @moduledoc """
  Main interface for release operations using :release_handler.

  This module provides a safe, high-level API for managing OTP releases
  with built-in validation, health checks, and rollback capabilities.
  """

  use GenServer
  require Logger

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Install a release without switching to it.

  This unpacks the release and makes it available for switching,
  but keeps the current release active.
  """
  def install_release(version) when is_binary(version) do
    GenServer.call(__MODULE__, {:install_release, version})
  end

  @doc """
  Switch to an installed release and make it permanent.

  This will restart the application with the new release.
  Includes pre/post switch validation and automatic rollback on failure.
  """
  def switch_release(version) when is_binary(version) do
    GenServer.call(__MODULE__, {:switch_release, version}, 60_000)
  end

  @doc """
  Rollback to the previous permanent release.
  """
  def rollback_release do
    GenServer.call(__MODULE__, :rollback_release, 60_000)
  end

  @doc """
  List all available releases.
  """
  def list_releases do
    GenServer.call(__MODULE__, :list_releases)
  end

  @doc """
  Get information about the current release.
  """
  def current_release do
    GenServer.call(__MODULE__, :current_release)
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:install_release, version}, _from, state) do
    result = do_install_release(version)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:switch_release, version}, _from, state) do
    result = do_switch_release(version)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:rollback_release, _from, state) do
    result = do_rollback_release()
    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_releases, _from, state) do
    result = do_list_releases()
    {:reply, result, state}
  end

  @impl true
  def handle_call(:current_release, _from, state) do
    result = do_current_release()
    {:reply, result, state}
  end

  # Private Implementation

  defp do_install_release(version) do
    Logger.info("Installing release #{version}")

    with :ok <- validate_release(version),
         {:ok, _} <- Bloom.ReleaseHandler.unpack_release(version),
         :ok <- verify_installation(version) do
      Logger.info("Successfully installed release #{version}")
      :ok
    else
      error ->
        Logger.error("Failed to install release #{version}: #{inspect(error)}")
        handle_release_error(error)
    end
  end

  defp do_switch_release(version) do
    Logger.info("Switching to release #{version}")

    with :ok <- pre_switch_checks(version),
         {:ok, backup_info} <- create_database_backup_if_needed(version),
         {:ok, migration_info} <- run_migrations_if_needed(version),
         {:ok, _} <- Bloom.ReleaseHandler.install_release(version),
         :ok <- post_switch_validation(),
         :ok <- Bloom.ReleaseHandler.make_permanent(version) do
      Logger.info("Successfully switched to release #{version}")
      log_successful_switch(version, backup_info, migration_info)
      :ok
    else
      error ->
        Logger.error("Failed to switch to release #{version}: #{inspect(error)}")
        attempt_rollback_with_database(version)
        handle_release_error(error)
    end
  end

  # Switch release without triggering rollback logic (used during rollback itself)
  defp do_switch_release_without_rollback(version) do
    Logger.info("Switching to release #{version}")

    with :ok <- pre_switch_checks(version),
         {:ok, _} <- Bloom.ReleaseHandler.install_release(version),
         :ok <- post_switch_validation(),
         :ok <- Bloom.ReleaseHandler.make_permanent(version) do
      Logger.info("Successfully switched to release #{version}")
      :ok
    else
      error ->
        Logger.error("Failed to switch to release #{version}: #{inspect(error)}")
        handle_release_error(error)
    end
  end

  defp do_rollback_release do
    Logger.info("Rolling back to previous release")

    case previous_release() do
      {_name, prev_version, _libs, _status} ->
        # Convert charlist to string if needed
        version_string = to_string(prev_version)
        do_switch_release(version_string)

      nil ->
        Logger.error("No previous release found for rollback")
        {:error, :no_previous_release}
    end
  end

  defp do_list_releases do
    Bloom.ReleaseHandler.which_releases()
    |> Enum.map(&format_release_info/1)
  end

  defp do_current_release do
    case Bloom.ReleaseHandler.which_releases(:current) do
      [{name, version, _libs, status}] ->
        {:ok, %{name: to_string(name), version: to_string(version), status: status}}

      [] ->
        {:error, :no_current_release}
    end
  end

  # Helper Functions

  defp validate_release(version) do
    Bloom.Validator.validate_release(version)
  end

  defp verify_installation(version) do
    # Verify the release was properly installed
    # This runs after unpack_release to ensure everything is in place
    Logger.debug("Verifying installation of release #{version}")

    # In test mode, skip file system verification
    if Application.get_env(:bloom, :skip_file_checks, false) do
      :ok
    else
      # Check that the release appears in the release handler's list
      case Bloom.ReleaseHandler.which_releases() do
        releases when is_list(releases) ->
          version_charlist = to_charlist(version)

          if Enum.any?(releases, fn {_name, v, _libs, _status} -> v == version_charlist end) do
            :ok
          else
            {:error, "Release #{version} not found in release handler after installation"}
          end

        _ ->
          {:error, "Unable to verify release installation"}
      end
    end
  end

  defp pre_switch_checks(version) do
    # Pre-switch validation to ensure system is ready for the switch
    Logger.debug("Running pre-switch checks for release #{version}")

    checks = [
      fn -> check_system_resources() end,
      fn -> check_release_compatibility(version) end,
      fn -> check_application_state() end
    ]

    case run_pre_switch_checks(checks) do
      :ok ->
        Logger.debug("Pre-switch checks passed for release #{version}")
        :ok

      {:error, reason} = error ->
        Logger.warning("Pre-switch checks failed for release #{version}: #{inspect(reason)}")
        error
    end
  end

  defp post_switch_validation do
    # TODO: Post-switch health checks
    # - Verify application started correctly
    # - Check critical services
    # - Validate basic functionality
    case Bloom.HealthChecker.post_switch_health_check() do
      true -> :ok
      false -> {:error, :health_check_failed}
    end
  end

  defp log_successful_switch(version, _backup_info, _migration_info) do
    Logger.info("Release switch completed successfully: #{version}")

    # Save deployment metadata
    case Bloom.Metadata.save_release_info(version) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to save release metadata: #{inspect(reason)}")
    end
  end

  defp previous_release do
    case Bloom.Metadata.get_rollback_target() do
      {:ok, version} ->
        # Return the release info tuple expected by the caller
        case Bloom.ReleaseHandler.which_releases() do
          releases when is_list(releases) ->
            Enum.find(releases, fn {_name, v, _libs, _status} ->
              to_string(v) == version
            end)

          _ ->
            nil
        end

      {:error, _reason} ->
        # Fallback to release_handler's previous release detection
        case Bloom.ReleaseHandler.which_releases() do
          [_current, previous | _] -> previous
          _ -> nil
        end
    end
  end

  defp format_release_info({name, version, _libs, status}) do
    %{
      name: to_string(name),
      version: to_string(version),
      status: status
    }
  end

  defp handle_release_error({:error, {:bad_relup_file, _}}) do
    {:error, "Invalid release upgrade file - check release compatibility"}
  end

  defp handle_release_error({:error, :bad_relup_file}) do
    {:error, "Invalid release upgrade file - check release compatibility"}
  end

  defp handle_release_error({:error, :no_such_release}) do
    {:error, "Release not found - ensure release is properly installed"}
  end

  defp handle_release_error({:error, {:already_installed, version}}) do
    {:error, "Release #{version} is already installed"}
  end

  defp handle_release_error(error) do
    {:error, "Release operation failed: #{inspect(error)}"}
  end

  # Pre-switch check helpers

  defp run_pre_switch_checks(checks) do
    results =
      Enum.map(checks, fn check_fn ->
        try do
          check_fn.()
        rescue
          error ->
            Logger.error("Pre-switch check failed with exception: #{inspect(error)}")
            {:error, {:exception, error}}
        end
      end)

    case Enum.find(results, fn result -> result != :ok end) do
      nil -> :ok
      error -> error
    end
  end

  defp check_system_resources do
    # Basic system resource checks
    memory_info = :erlang.memory()
    total_memory = Keyword.get(memory_info, :total, 0)
    process_count = :erlang.system_info(:process_count)
    process_limit = :erlang.system_info(:process_limit)

    cond do
      total_memory == 0 ->
        {:error, :invalid_memory_info}

      process_count / process_limit > 0.9 ->
        {:error, :high_process_usage}

      true ->
        :ok
    end
  end

  defp check_release_compatibility(version) do
    # Check compatibility with current release
    case do_current_release() do
      {:ok, %{version: current_version}} ->
        Bloom.Validator.check_compatibility(current_version, version)

      _ ->
        # No current release, assume compatible
        :ok
    end
  end

  defp check_application_state do
    # Ensure application is in a good state for switching
    case Bloom.HealthChecker.post_switch_health_check() do
      true -> :ok
      false -> {:error, :application_unhealthy}
    end
  end

  defp alert_rollback_failure(reason) do
    # Hook for external monitoring/alerting systems
    # Applications can override this by configuring a callback
    case Application.get_env(:bloom, :rollback_failure_callback) do
      nil ->
        Logger.critical("ROLLBACK FAILURE: #{inspect(reason)}")

      callback when is_function(callback, 1) ->
        callback.(reason)

      {module, function} ->
        apply(module, function, [reason])
    end
  end

  # Database rollback functions

  defp create_database_backup_if_needed(version) do
    case has_pending_migrations?() do
      true ->
        Logger.info("Pending migrations detected, creating database backup")
        Bloom.DatabaseBackup.create_backup(version)

      false ->
        Logger.debug("No pending migrations, skipping database backup")
        {:ok, :no_backup_needed}
    end
  end

  defp run_migrations_if_needed(version) do
    case Bloom.MigrationTracker.check_pending_migrations() do
      pending when map_size(pending) > 0 ->
        Logger.info("Running pending migrations for deployment #{version}")

        case Bloom.MigrationTracker.run_pending_migrations() do
          {:ok, executed_migrations} ->
            # Save migration info for potential rollback
            Bloom.MigrationTracker.save_migration_info(version, executed_migrations)
            {:ok, executed_migrations}

          {:error, reason} ->
            Logger.error("Migration execution failed: #{inspect(reason)}")
            {:error, {:migration_failed, reason}}
        end

      _empty ->
        Logger.debug("No pending migrations for deployment #{version}")
        {:ok, :no_migrations}
    end
  end

  defp has_pending_migrations? do
    case Bloom.MigrationTracker.check_pending_migrations() do
      pending when map_size(pending) > 0 -> true
      _ -> false
    end
  end

  defp attempt_rollback_with_database(failed_version) do
    Logger.warning("Attempting automatic rollback with database recovery")

    # First try to rollback migrations if they were run
    case rollback_migrations_if_needed(failed_version) do
      :ok ->
        Logger.info("Database migrations rolled back successfully")

      {:error, reason} ->
        Logger.warning("Migration rollback failed, attempting backup restore: #{inspect(reason)}")

        case restore_database_backup_if_needed(failed_version) do
          :ok ->
            Logger.info("Database backup restored successfully")

          {:error, backup_reason} ->
            Logger.error("Database backup restore failed: #{inspect(backup_reason)}")
        end
    end

    # Then try application rollback - but avoid infinite loops
    Logger.info("Rolling back to previous release")
    
    case Bloom.Metadata.get_rollback_target() do
      {:ok, target_version} ->
        # Check if target is different from current to avoid infinite loop
        case do_current_release() do
          {:ok, current_version} when current_version != target_version ->
            case do_switch_release_without_rollback(target_version) do
              :ok ->
                Logger.info("Automatic rollback completed successfully")
                :ok

              {:error, reason} ->
                Logger.error("Automatic rollback failed: #{inspect(reason)}")
                alert_rollback_failure(reason)
                {:error, reason}
            end

          _ ->
            Logger.warning("Cannot rollback: target version same as current or unknown")
            {:error, :no_valid_rollback_target}
        end

      {:error, reason} ->
        Logger.error("Could not find rollback target: #{inspect(reason)}")
        alert_rollback_failure(reason)
        {:error, reason}
    end
  end

  defp rollback_migrations_if_needed(version) do
    strategy = Application.get_env(:bloom, :database_migration_rollback_strategy, :ecto_first)

    case strategy do
      :skip ->
        Logger.info("Migration rollback disabled by configuration")
        :ok

      :backup_only ->
        Logger.info("Using backup-only strategy, skipping migration rollback")
        {:error, :backup_only_strategy}

      :ecto_first ->
        case Bloom.MigrationTracker.rollback_deployment_migrations(version) do
          {:ok, :no_migrations} ->
            Logger.debug("No migrations to rollback")
            :ok

          {:ok, rolled_back} ->
            Logger.info("Successfully rolled back migrations: #{inspect(rolled_back)}")
            :ok

          {:error, reason} ->
            Logger.warning("Migration rollback failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp restore_database_backup_if_needed(version) do
    case Bloom.DatabaseBackup.restore_backup(version) do
      :ok ->
        Logger.info("Database backup restored for version #{version}")
        :ok

      {:error, :no_backup_available} ->
        Logger.warning("No database backup available for version #{version}")
        # Not an error if no backup was created
        :ok

      {:error, reason} ->
        Logger.error("Database backup restore failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
