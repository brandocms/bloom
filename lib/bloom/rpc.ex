defmodule Bloom.RPC do
  @moduledoc """
  RPC interface for external communication with Bloom.

  This module handles remote procedure calls from Florist CLI,
  providing a secure interface for release management operations.
  """

  use GenServer
  require Logger

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Handle a remote procedure call from Florist CLI.

  This is the main entry point for external RPC calls.
  """
  def handle_remote_call(operation, args, caller_info \\ nil) do
    GenServer.call(__MODULE__, {:remote_call, operation, args, caller_info})
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    Logger.info("Bloom RPC interface started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:remote_call, operation, args, caller_info}, _from, state) do
    result =
      with :ok <- authenticate_caller(caller_info),
           {:ok, response} <- execute_operation(operation, args) do
        {:ok, response}
      else
        {:error, reason} ->
          Logger.warning("RPC call failed: #{inspect(reason)}")
          {:error, reason}
      end

    {:reply, result, state}
  end

  # Standard RPC Handlers for :rpc.call/5

  @doc """
  Install a release via RPC.

  This function is called by Florist via :rpc.call/5
  """
  def install_release(version) do
    Logger.info("RPC: install_release #{version}")
    Bloom.ReleaseManager.install_release(version)
  end

  @doc """
  Switch to a release via RPC.

  This function is called by Florist via :rpc.call/5
  """
  def switch_release(version) do
    Logger.info("RPC: switch_release #{version}")
    Bloom.ReleaseManager.switch_release(version)
  end

  @doc """
  List releases via RPC.

  This function is called by Florist via :rpc.call/5
  """
  def list_releases do
    Logger.info("RPC: list_releases")
    Bloom.ReleaseManager.list_releases()
  end

  @doc """
  Get current release via RPC.

  This function is called by Florist via :rpc.call/5
  """
  def current_release do
    Logger.info("RPC: current_release")
    Bloom.ReleaseManager.current_release()
  end

  @doc """
  Rollback release via RPC.

  This function is called by Florist via :rpc.call/5
  """
  def rollback_release do
    Logger.info("RPC: rollback_release")
    Bloom.ReleaseManager.rollback_release()
  end

  @doc """
  Run health checks via RPC.

  This function is called by Florist via :rpc.call/5
  """
  def health_check do
    Logger.info("RPC: health_check")

    case Bloom.HealthChecker.run_checks() do
      true -> :ok
      false -> {:error, :health_check_failed}
    end
  end

  # Private Implementation

  defp execute_operation(:install_release, [version]) do
    result = Bloom.ReleaseManager.install_release(version)
    {:ok, result}
  end

  defp execute_operation(:switch_release, [version]) do
    result = Bloom.ReleaseManager.switch_release(version)
    {:ok, result}
  end

  defp execute_operation(:list_releases, []) do
    result = Bloom.ReleaseManager.list_releases()
    {:ok, result}
  end

  defp execute_operation(:current_release, []) do
    result = Bloom.ReleaseManager.current_release()
    {:ok, result}
  end

  defp execute_operation(:rollback_release, []) do
    result = Bloom.ReleaseManager.rollback_release()
    {:ok, result}
  end

  defp execute_operation(:health_check, []) do
    result =
      case Bloom.HealthChecker.run_checks() do
        true -> :ok
        false -> {:error, :health_check_failed}
      end

    {:ok, result}
  end

  defp execute_operation(operation, _args) do
    {:error, {:unknown_operation, operation}}
  end

  defp authenticate_caller(nil) do
    # For now, allow unauthenticated calls
    # TODO: Implement proper authentication
    :ok
  end

  defp authenticate_caller(_caller_info) do
    # TODO: Implement authentication logic
    # This could check:
    # - Shared secrets
    # - Certificates
    # - IP address allowlists
    # - Time-based tokens
    :ok
  end
end
