defmodule Bloom.HealthChecker do
  @moduledoc """
  Health monitoring and validation for release operations.
  
  Provides a framework for running health checks after release switches
  and allows applications to register custom health validation functions.
  """
  
  use GenServer
  require Logger

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a custom health check function.
  
  ## Examples
      
      Bloom.HealthChecker.register_check(:database, &MyApp.DatabaseChecker.check/0)
      Bloom.HealthChecker.register_check(:cache, &MyApp.CacheChecker.check/0)
  """
  def register_check(name, check_function) when is_atom(name) and is_function(check_function, 0) do
    GenServer.call(__MODULE__, {:register_check, name, check_function})
  end

  @doc """
  Run all registered health checks.
  
  Returns `true` if all checks pass, `false` if any fail.
  """
  def run_checks do
    GenServer.call(__MODULE__, :run_checks, 30_000)
  end

  @doc """
  Run post-switch health validation.
  
  This is called automatically after a release switch to validate
  that the application is functioning correctly.
  """
  def post_switch_health_check do
    GenServer.call(__MODULE__, :post_switch_health_check, 30_000)
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    # Initialize with basic system health checks
    checks = %{
      application: &check_application_started/0,
      memory: &check_memory_usage/0,
      processes: &check_process_count/0
    }
    
    {:ok, %{checks: checks}}
  end

  @impl true
  def handle_call({:register_check, name, check_function}, _from, state) do
    new_checks = Map.put(state.checks, name, check_function)
    new_state = %{state | checks: new_checks}
    Logger.info("Registered health check: #{name}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:run_checks, _from, state) do
    result = execute_all_checks(state.checks)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:post_switch_health_check, _from, state) do
    Logger.info("Running post-switch health checks")
    result = execute_critical_checks(state.checks)
    {:reply, result, state}
  end

  # Private Implementation

  defp execute_all_checks(checks) do
    results = 
      checks
      |> Enum.map(fn {name, check_fn} ->
        {name, run_single_check(name, check_fn)}
      end)
    
    failed_checks = 
      results
      |> Enum.filter(fn {_name, result} -> result != :ok end)
    
    if Enum.empty?(failed_checks) do
      Logger.info("All health checks passed")
      true
    else
      Logger.warning("Health checks failed: #{inspect(failed_checks)}")
      false
    end
  end

  defp execute_critical_checks(checks) do
    # Run only critical checks for post-switch validation
    critical_checks = [:application, :memory, :processes]
    
    critical_results =
      checks
      |> Enum.filter(fn {name, _} -> name in critical_checks end)
      |> Enum.map(fn {name, check_fn} ->
        {name, run_single_check(name, check_fn)}
      end)
    
    failed_critical = 
      critical_results
      |> Enum.filter(fn {_name, result} -> result != :ok end)
    
    if Enum.empty?(failed_critical) do
      Logger.info("Critical health checks passed")
      true
    else
      Logger.error("Critical health checks failed: #{inspect(failed_critical)}")
      false
    end
  end

  defp run_single_check(name, check_function) do
    try do
      case check_function.() do
        :ok -> :ok
        true -> :ok
        false -> {:error, :check_failed}
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_return, other}}
      end
    rescue
      error ->
        Logger.error("Health check #{name} raised exception: #{inspect(error)}")
        {:error, {:exception, error}}
    catch
      kind, reason ->
        Logger.error("Health check #{name} threw #{kind}: #{inspect(reason)}")
        {:error, {:throw, kind, reason}}
    end
  end

  # Default Health Checks

  defp check_application_started do
    # Check if the main application is running
    case Application.started_applications() do
      apps when is_list(apps) ->
        # TODO: Get the actual application name from config
        # For now, just check that we have some applications running
        if length(apps) > 0, do: :ok, else: {:error, :no_applications}
      _ ->
        {:error, :cannot_get_applications}
    end
  end

  defp check_memory_usage do
    # Check if memory usage is within acceptable limits
    memory_info = :erlang.memory()
    total_memory = Keyword.get(memory_info, :total, 0)
    
    # TODO: Make threshold configurable
    # For now, just check that we have some memory usage (sanity check)
    if total_memory > 0, do: :ok, else: {:error, :invalid_memory_info}
  end

  defp check_process_count do
    # Check if process count is reasonable
    process_count = :erlang.system_info(:process_count)
    
    # TODO: Make thresholds configurable
    # Basic sanity check - should have more than 10 processes
    if process_count > 10, do: :ok, else: {:error, :too_few_processes}
  end
end