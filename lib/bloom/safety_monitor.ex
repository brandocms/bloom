defmodule Bloom.SafetyMonitor do
  @moduledoc """
  Safety monitoring for release operations with automatic rollback capabilities.

  This GenServer monitors critical system metrics during and after release
  switches, automatically triggering rollbacks if critical failures are detected.
  """

  use GenServer
  require Logger

  # 5 minutes
  @default_monitor_timeout 300_000
  # 10 seconds
  @default_check_interval 10_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start monitoring a release switch operation.

  This begins active monitoring for the specified duration, checking
  critical metrics and automatically rolling back if issues are detected.
  """
  def start_monitoring_switch(from_version, to_version, opts \\ []) do
    GenServer.call(__MODULE__, {:start_monitoring, from_version, to_version, opts})
  end

  @doc """
  Stop monitoring and clear the current monitoring session.
  """
  def stop_monitoring do
    GenServer.call(__MODULE__, :stop_monitoring)
  end

  @doc """
  Get the current monitoring status.
  """
  def monitoring_status do
    GenServer.call(__MODULE__, :monitoring_status)
  end

  @doc """
  Force a health check evaluation.
  """
  def force_health_check do
    GenServer.call(__MODULE__, :force_health_check)
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    Logger.info("Bloom SafetyMonitor started")

    state = %{
      monitoring: false,
      from_version: nil,
      to_version: nil,
      monitor_start: nil,
      monitor_timeout: @default_monitor_timeout,
      check_interval: @default_check_interval,
      failure_count: 0,
      max_failures: 3
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_monitoring, from_version, to_version, opts}, _from, state) do
    if state.monitoring do
      {:reply, {:error, :already_monitoring}, state}
    else
      timeout = Keyword.get(opts, :timeout, @default_monitor_timeout)
      interval = Keyword.get(opts, :check_interval, @default_check_interval)
      max_failures = Keyword.get(opts, :max_failures, 3)

      new_state = %{
        state
        | monitoring: true,
          from_version: from_version,
          to_version: to_version,
          monitor_start: System.system_time(:millisecond),
          monitor_timeout: timeout,
          check_interval: interval,
          max_failures: max_failures,
          failure_count: 0
      }

      # Schedule first health check
      Process.send_after(self(), :check_health, interval)

      # Schedule timeout
      Process.send_after(self(), :monitor_timeout, timeout)

      Logger.info(
        "Started monitoring switch: #{from_version} -> #{to_version} (timeout: #{timeout}ms)"
      )

      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:stop_monitoring, _from, state) do
    if state.monitoring do
      Logger.info("Stopping safety monitoring")

      new_state = %{
        state
        | monitoring: false,
          from_version: nil,
          to_version: nil,
          failure_count: 0
      }

      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_monitoring}, state}
    end
  end

  @impl true
  def handle_call(:monitoring_status, _from, state) do
    status =
      if state.monitoring do
        elapsed = System.system_time(:millisecond) - state.monitor_start
        remaining = max(0, state.monitor_timeout - elapsed)

        %{
          monitoring: true,
          from_version: state.from_version,
          to_version: state.to_version,
          elapsed_ms: elapsed,
          remaining_ms: remaining,
          failure_count: state.failure_count,
          max_failures: state.max_failures
        }
      else
        %{monitoring: false}
      end

    {:reply, status, state}
  end

  @impl true
  def handle_call(:force_health_check, _from, state) do
    if state.monitoring do
      result = perform_health_check(state)
      {:reply, result, state}
    else
      {:reply, {:error, :not_monitoring}, state}
    end
  end

  @impl true
  def handle_info(:check_health, %{monitoring: true} = state) do
    case perform_health_check(state) do
      :ok ->
        # Health check passed, schedule next check
        Process.send_after(self(), :check_health, state.check_interval)
        # Reset failure count on success
        new_state = %{state | failure_count: 0}
        {:noreply, new_state}

      {:error, reason} ->
        new_failure_count = state.failure_count + 1

        Logger.warning(
          "Health check failed (#{new_failure_count}/#{state.max_failures}): #{inspect(reason)}"
        )

        if new_failure_count >= state.max_failures do
          Logger.error("Maximum failures reached, initiating automatic rollback")
          initiate_automatic_rollback(state)
          new_state = %{state | monitoring: false, failure_count: 0}
          {:noreply, new_state}
        else
          # Continue monitoring but track the failure
          Process.send_after(self(), :check_health, state.check_interval)
          new_state = %{state | failure_count: new_failure_count}
          {:noreply, new_state}
        end
    end
  end

  @impl true
  def handle_info(:check_health, state) do
    # Not monitoring, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(:monitor_timeout, %{monitoring: true} = state) do
    Logger.info("Safety monitoring timeout reached, monitoring session complete")
    new_state = %{state | monitoring: false, from_version: nil, to_version: nil, failure_count: 0}
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:monitor_timeout, state) do
    # Not monitoring, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("SafetyMonitor received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Implementation

  defp perform_health_check(_state) do
    Logger.debug("Performing safety health check")

    checks = [
      &check_application_health/0,
      &check_memory_usage/0,
      &check_process_stability/0,
      &check_error_rate/0,
      &check_response_time/0
    ]

    case run_safety_checks(checks) do
      :ok ->
        Logger.debug("Safety health check passed")
        :ok

      {:error, reason} = error ->
        Logger.warning("Safety health check failed: #{inspect(reason)}")
        error
    end
  end

  defp run_safety_checks(checks) do
    results =
      Enum.map(checks, fn check_fn ->
        try do
          check_fn.()
        rescue
          error ->
            Logger.error("Safety check failed with exception: #{inspect(error)}")
            {:error, {:exception, error}}
        end
      end)

    case Enum.find(results, fn result -> result != :ok end) do
      nil -> :ok
      error -> error
    end
  end

  defp check_application_health do
    # Use the HealthChecker for basic application health
    case Bloom.HealthChecker.post_switch_health_check() do
      true -> :ok
      false -> {:error, :application_health_failed}
    end
  end

  defp check_memory_usage do
    memory_info = :erlang.memory()
    total_memory = Keyword.get(memory_info, :total, 0)

    # Get memory threshold from config (default to 1GB)
    threshold = Application.get_env(:bloom, :memory_threshold_bytes, 1_073_741_824)

    if total_memory < threshold do
      :ok
    else
      {:error, {:memory_threshold_exceeded, total_memory, threshold}}
    end
  end

  defp check_process_stability do
    process_count = :erlang.system_info(:process_count)
    process_limit = :erlang.system_info(:process_limit)

    # Check that we're not using too much of the process table
    usage_ratio = process_count / process_limit

    # Less than 80% usage
    if usage_ratio < 0.8 do
      :ok
    else
      {:error, {:process_count_high, process_count, process_limit}}
    end
  end

  defp check_error_rate do
    # TODO: Implement error rate monitoring
    # This could check:
    # - Application error logs
    # - HTTP error rates
    # - GenServer crash rates
    # - Supervisor restart counts
    :ok
  end

  defp check_response_time do
    # TODO: Implement response time monitoring
    # This could check:
    # - HTTP endpoint response times
    # - Database query times
    # - Message queue processing times
    :ok
  end

  defp initiate_automatic_rollback(state) do
    Logger.error(
      "SAFETY CRITICAL: Initiating automatic rollback from #{state.to_version} to #{state.from_version}"
    )

    # Attempt rollback in a separate process to avoid blocking the monitor
    Task.start(fn ->
      case Bloom.ReleaseManager.rollback_release() do
        :ok ->
          Logger.info("Automatic rollback completed successfully")

        {:error, reason} ->
          Logger.error("Automatic rollback failed: #{inspect(reason)}")
          # TODO: Alert external systems of critical failure
      end
    end)
  end
end
