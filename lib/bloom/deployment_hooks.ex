defmodule Bloom.DeploymentHooks do
  @moduledoc """
  Registry and management system for deployment hooks.

  Provides a structured way to register, manage, and execute hooks during
  different phases of deployment. Hooks can be used to integrate with
  external systems, run custom validation, or perform cleanup tasks.
  """

  require Logger

  @doc """
  Register a deployment hook for a specific phase.

  Phase can be:
  - `:pre_deployment` - Run before deployment starts
  - `:post_deployment` - Run after successful deployment
  - `:on_failure` - Run when deployment fails
  - `:pre_rollback` - Run before rollback starts
  - `:post_rollback` - Run after rollback completes
  """
  def register_hook(phase, hook_module, opts \\ [])
      when phase in [
             :pre_deployment,
             :post_deployment,
             :on_failure,
             :pre_rollback,
             :post_rollback
           ] do
    hook_config = %{
      module: hook_module,
      priority: Keyword.get(opts, :priority, 50),
      timeout: Keyword.get(opts, :timeout, 30_000),
      retry_count: Keyword.get(opts, :retry_count, 0),
      enabled: Keyword.get(opts, :enabled, true)
    }

    hooks = get_hooks_registry()
    phase_hooks = Map.get(hooks, phase, [])
    updated_hooks = [hook_config | phase_hooks]
    sorted_hooks = Enum.sort_by(updated_hooks, & &1.priority)

    new_registry = Map.put(hooks, phase, sorted_hooks)
    put_hooks_registry(new_registry)

    Logger.info(
      "Registered #{hook_module} for #{phase} phase (priority: #{hook_config.priority})"
    )

    :ok
  end

  @doc """
  Unregister a hook from a specific phase.
  """
  def unregister_hook(phase, hook_module) do
    hooks = get_hooks_registry()
    phase_hooks = Map.get(hooks, phase, [])
    updated_hooks = Enum.reject(phase_hooks, fn hook -> hook.module == hook_module end)

    new_registry = Map.put(hooks, phase, updated_hooks)
    put_hooks_registry(new_registry)

    Logger.info("Unregistered #{hook_module} from #{phase} phase")
    :ok
  end

  @doc """
  Execute all hooks for a given phase.
  """
  def execute_hooks(phase, context) do
    hooks = get_hooks_for_phase(phase)

    Logger.debug("Executing #{length(hooks)} hooks for #{phase} phase")

    Enum.reduce_while(hooks, :ok, fn hook, _acc ->
      if hook.enabled do
        case execute_single_hook(hook, context) do
          :ok ->
            Logger.debug("Hook #{hook.module} completed successfully")
            {:cont, :ok}

          {:ok, _result} ->
            Logger.debug("Hook #{hook.module} completed successfully")
            {:cont, :ok}

          {:error, reason} ->
            Logger.error("Hook #{hook.module} failed: #{inspect(reason)}")
            {:halt, {:error, "Hook #{hook.module} failed: #{inspect(reason)}"}}
        end
      else
        Logger.debug("Skipping disabled hook #{hook.module}")
        {:cont, :ok}
      end
    end)
  end

  @doc """
  Get all registered hooks for a phase.
  """
  def get_hooks_for_phase(phase) do
    hooks = get_hooks_registry()
    Map.get(hooks, phase, [])
  end

  @doc """
  Enable or disable a specific hook.
  """
  def set_hook_enabled(phase, hook_module, enabled) do
    hooks = get_hooks_registry()
    phase_hooks = Map.get(hooks, phase, [])

    updated_hooks =
      Enum.map(phase_hooks, fn hook ->
        if hook.module == hook_module do
          %{hook | enabled: enabled}
        else
          hook
        end
      end)

    new_registry = Map.put(hooks, phase, updated_hooks)
    put_hooks_registry(new_registry)

    status = if enabled, do: "enabled", else: "disabled"
    Logger.info("Hook #{hook_module} #{status} for #{phase} phase")
    :ok
  end

  @doc """
  Clear all hooks for a phase or all phases.
  """
  def clear_hooks(phase \\ :all) do
    case phase do
      :all ->
        put_hooks_registry(%{})
        Logger.info("Cleared all deployment hooks")

      specific_phase ->
        hooks = get_hooks_registry()
        new_registry = Map.delete(hooks, specific_phase)
        put_hooks_registry(new_registry)
        Logger.info("Cleared all hooks for #{specific_phase} phase")
    end

    :ok
  end

  @doc """
  Get a summary of all registered hooks.
  """
  def list_hooks do
    hooks = get_hooks_registry()

    summary =
      Enum.map(hooks, fn {phase, phase_hooks} ->
        hook_summaries =
          Enum.map(phase_hooks, fn hook ->
            %{
              module: hook.module,
              priority: hook.priority,
              timeout: hook.timeout,
              enabled: hook.enabled
            }
          end)

        {phase, hook_summaries}
      end)

    {:ok, summary}
  end

  # Private functions

  defp execute_single_hook(hook, context) do
    task =
      Task.async(fn ->
        try do
          hook.module.execute(context)
        rescue
          error -> {:error, {:hook_crashed, error}}
        catch
          :exit, reason -> {:error, {:hook_exited, reason}}
          :throw, reason -> {:error, {:hook_threw, reason}}
        end
      end)

    case Task.yield(task, hook.timeout) || Task.shutdown(task) do
      {:ok, result} ->
        execute_with_retry(hook, context, result, hook.retry_count)

      nil ->
        {:error, :timeout}
    end
  end

  defp execute_with_retry(_hook, _context, {:ok, result}, _retries_left), do: {:ok, result}
  defp execute_with_retry(_hook, _context, :ok, _retries_left), do: :ok
  defp execute_with_retry(_hook, _context, {:error, reason}, 0), do: {:error, reason}

  defp execute_with_retry(hook, context, {:error, _reason}, retries_left) when retries_left > 0 do
    Logger.warning("Retrying hook #{hook.module} (#{retries_left} retries left)")

    # Add a small delay before retry
    :timer.sleep(1000)

    case execute_single_hook(%{hook | retry_count: 0}, context) do
      :ok -> :ok
      {:ok, result} -> {:ok, result}
      {:error, reason} -> execute_with_retry(hook, context, {:error, reason}, retries_left - 1)
    end
  end

  defp get_hooks_registry do
    Application.get_env(:bloom, :deployment_hooks_registry, %{})
  end

  defp put_hooks_registry(registry) do
    Application.put_env(:bloom, :deployment_hooks_registry, registry)
  end
end
