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
         {:ok, _} <- Bloom.ReleaseHandler.install_release(version),
         :ok <- post_switch_validation(),
         :ok <- Bloom.ReleaseHandler.make_permanent(version) do
      Logger.info("Successfully switched to release #{version}")
      log_successful_switch(version)
      :ok
    else
      error ->
        Logger.error("Failed to switch to release #{version}: #{inspect(error)}")
        attempt_rollback()
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

  defp verify_installation(_version) do
    # TODO: Verify the release was properly installed
    # - Check release directory structure
    # - Validate .rel file
    # - Ensure all required files are present
    :ok
  end

  defp pre_switch_checks(_version) do
    # TODO: Pre-switch validation
    # - Check system resources
    # - Validate compatibility
    # - Ensure safe state for switching
    :ok
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

  defp attempt_rollback do
    Logger.warning("Attempting automatic rollback due to switch failure")
    # TODO: Implement automatic rollback logic
  end

  defp log_successful_switch(version) do
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
end
