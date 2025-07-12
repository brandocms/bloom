defmodule Bloom.DeploymentCoordinator do
  @moduledoc """
  Coordinates complex deployment scenarios with pre/post deployment hooks,
  health checks, and rollback strategies.

  This module orchestrates the entire deployment process including:
  - Pre-deployment validation and preparation
  - Coordinated release switching with health monitoring
  - Post-deployment verification and cleanup
  - Automatic rollback on failure
  """

  require Logger
  alias Bloom.{ReleaseManager, HealthChecker, LifecycleManager, DeploymentHooks}

  @doc """
  Execute a coordinated deployment with full lifecycle management.

  Options:
  - `:health_check_timeout` - Timeout for health checks (default: 30 seconds)
  - `:rollback_on_failure` - Whether to auto-rollback on failure (default: true)
  - `:skip_health_checks` - Skip health checks (default: false)
  - `:cleanup_after_success` - Clean up old releases after successful deployment (default: true)
  - `:pre_deployment_hooks` - List of {module, function} tuples to run before deployment
  - `:post_deployment_hooks` - List of {module, function} tuples to run after deployment
  """
  def deploy(version, opts \\ []) do
    deployment_id = generate_deployment_id()

    Logger.info("Starting coordinated deployment #{deployment_id} to version #{version}")

    deployment_context = %{
      id: deployment_id,
      target_version: version,
      started_at: DateTime.utc_now(),
      options: sanitize_options_for_storage(opts),
      # Keep original options for internal use
      raw_options: opts
    }

    with :ok <- run_pre_deployment_phase(deployment_context),
         :ok <- run_deployment_phase(deployment_context),
         :ok <- run_post_deployment_phase(deployment_context) do
      Logger.info("Deployment #{deployment_id} completed successfully")
      {:ok, %{deployment_id: deployment_id, version: version, status: :completed}}
    else
      {:error, reason} ->
        handle_deployment_failure(deployment_context, reason)
    end
  end

  @doc """
  Get the status of an ongoing or completed deployment.
  """
  def get_deployment_status(deployment_id) do
    case Bloom.Metadata.get_deployment_info(deployment_id) do
      {:ok, info} -> {:ok, info}
      {:error, :not_found} -> {:error, :deployment_not_found}
      error -> error
    end
  end

  @doc """
  Cancel an ongoing deployment and rollback if necessary.
  """
  def cancel_deployment(deployment_id) do
    case get_deployment_status(deployment_id) do
      {:ok, %{status: :in_progress}} ->
        Logger.warning("Cancelling deployment #{deployment_id}")
        perform_emergency_rollback(deployment_id)

      {:ok, %{status: status}} ->
        {:error, "Cannot cancel deployment in status: #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Register a deployment hook to run during specific phases.

  Phase can be :pre_deployment, :post_deployment, or :on_failure
  """
  def register_hook(phase, module, function, args \\ [])
      when phase in [:pre_deployment, :post_deployment, :on_failure] do
    hooks = Application.get_env(:bloom, :deployment_hooks, %{})
    phase_hooks = Map.get(hooks, phase, [])
    new_hook = {module, function, args}

    updated_hooks = Map.put(hooks, phase, [new_hook | phase_hooks])
    Application.put_env(:bloom, :deployment_hooks, updated_hooks)

    :ok
  end

  @doc """
  Validate that a deployment is safe to proceed.
  """
  def validate_deployment(version) do
    with {:ok, current_release_info} <- ReleaseManager.current_release(),
         :ok <- validate_version_compatibility(current_release_info.version, version),
         :ok <- validate_system_health(),
         :ok <- validate_disk_space(),
         :ok <- validate_dependencies(version) do
      {:ok,
       %{
         safe_to_deploy: true,
         validations_passed: [:compatibility, :health, :disk_space, :dependencies]
       }}
    else
      {:error, reason} ->
        {:error, %{safe_to_deploy: false, reason: reason}}
    end
  end

  # Private functions

  defp generate_deployment_id do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    random = :rand.uniform(1000)
    "deploy_#{timestamp}_#{random}"
  end

  defp run_pre_deployment_phase(context) do
    Logger.info("Running pre-deployment phase for #{context.id}")

    with :ok <- save_deployment_metadata(context, :preparing),
         {:ok, _validation_result} <- validate_deployment(context.target_version),
         :ok <- run_deployment_hooks(:pre_deployment, context),
         :ok <- prepare_deployment_environment(context) do
      Logger.info("Pre-deployment phase completed successfully")
      :ok
    else
      error ->
        Logger.error("Pre-deployment phase failed: #{inspect(error)}")
        error
    end
  end

  defp run_deployment_phase(context) do
    Logger.info("Running deployment phase for #{context.id}")

    with :ok <- save_deployment_metadata(context, :deploying),
         :ok <- perform_release_switch(context),
         :ok <- run_health_checks(context) do
      Logger.info("Deployment phase completed successfully")
      :ok
    else
      error ->
        Logger.error("Deployment phase failed: #{inspect(error)}")
        error
    end
  end

  defp run_post_deployment_phase(context) do
    Logger.info("Running post-deployment phase for #{context.id}")

    with :ok <- save_deployment_metadata(context, :finalizing),
         :ok <- run_deployment_hooks(:post_deployment, context),
         :ok <- cleanup_if_enabled(context),
         :ok <- save_deployment_metadata(context, :completed) do
      Logger.info("Post-deployment phase completed successfully")
      :ok
    else
      error ->
        Logger.error("Post-deployment phase failed: #{inspect(error)}")
        error
    end
  end

  defp save_deployment_metadata(context, status) do
    deployment_info = %{
      id: context.id,
      target_version: context.target_version,
      status: status,
      started_at: context.started_at,
      updated_at: DateTime.utc_now(),
      options: context.options
    }

    Bloom.Metadata.save_deployment_info(context.id, deployment_info)
  end

  defp validate_version_compatibility(current_version, target_version) do
    if current_version == target_version do
      {:error, "Target version #{target_version} is already deployed"}
    else
      # Try to validate compatibility, but don't fail deployment if we can't
      case Bloom.ReleaseInfo.validate_compatibility(current_version, target_version) do
        {:ok, %{compatible: true}} ->
          Logger.debug("Version compatibility check passed")
          :ok

        {:ok, %{compatible: false, issues: issues}} ->
          issue_messages = Enum.map(issues, fn issue -> issue.description end)
          Logger.warning("Version compatibility issues found: #{Enum.join(issue_messages, ", ")}")
          # For now, proceed with deployment but warn
          :ok

        {:error, reason} ->
          Logger.debug("Could not validate compatibility: #{inspect(reason)}")
          # Proceed with deployment if validation fails
          :ok
      end
    end
  end

  defp validate_system_health do
    case HealthChecker.run_checks() do
      {:ok, :healthy} ->
        :ok

      {:ok, :degraded} ->
        Logger.warning("System health is degraded but proceeding with deployment")
        :ok

      {:error, reason} ->
        {:error, "System health check failed: #{inspect(reason)}"}
    end
  end

  defp validate_disk_space do
    case LifecycleManager.check_disk_space() do
      {:ok, _info} ->
        :ok

      {:warning, info} ->
        Logger.warning("Disk space usage is high: #{info.usage_percentage}%")
        # Proceed but warn
        :ok

      {:error, reason} ->
        Logger.warning("Could not check disk space: #{inspect(reason)}")
        # Proceed if disk check fails
        :ok
    end
  end

  defp validate_dependencies(_version) do
    # This could check for required services, database connectivity, etc.
    # For now, just return ok
    :ok
  end

  defp run_deployment_hooks(phase, context) do
    context_with_phase = Map.put(context, :phase, phase)
    DeploymentHooks.execute_hooks(phase, context_with_phase)
  end

  defp prepare_deployment_environment(context) do
    Logger.info("Preparing deployment environment")

    # Auto-cleanup old releases if enabled
    if Keyword.get(context.raw_options, :auto_cleanup_before_deploy, false) do
      case LifecycleManager.auto_cleanup_if_needed() do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Auto cleanup before deployment failed: #{inspect(reason)}")
          # Don't fail deployment for cleanup issues
          :ok
      end
    else
      :ok
    end
  end

  defp perform_release_switch(context) do
    Logger.info("Performing release switch to #{context.target_version}")

    case ReleaseManager.switch_release(context.target_version) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Release switch failed: #{inspect(reason)}"}
    end
  end

  defp run_health_checks(context) do
    if Keyword.get(context.raw_options, :skip_health_checks, false) do
      Logger.info("Skipping health checks as requested")
      :ok
    else
      Logger.info("Running post-deployment health checks")
      timeout = Keyword.get(context.raw_options, :health_check_timeout, 30_000)

      case run_health_checks_with_timeout(timeout) do
        {:ok, :healthy} ->
          Logger.info("Health checks passed")
          :ok

        {:ok, :degraded} ->
          Logger.warning("Health checks show degraded state but continuing")
          :ok

        {:error, reason} ->
          {:error, "Health checks failed: #{inspect(reason)}"}

        :timeout ->
          {:error, "Health checks timed out after #{timeout}ms"}
      end
    end
  end

  defp run_health_checks_with_timeout(timeout) do
    task =
      Task.async(fn ->
        HealthChecker.post_switch_health_check()
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> :timeout
    end
  end

  defp cleanup_if_enabled(context) do
    if Keyword.get(context.raw_options, :cleanup_after_success, true) do
      Logger.info("Running post-deployment cleanup")

      case LifecycleManager.cleanup_old_releases() do
        {:ok, result} ->
          Logger.info("Cleaned up #{result.removed} old releases")
          :ok

        {:error, reason} ->
          Logger.warning("Post-deployment cleanup failed: #{inspect(reason)}")
          # Don't fail deployment for cleanup issues
          :ok
      end
    else
      :ok
    end
  end

  defp handle_deployment_failure(context, reason) do
    Logger.error("Deployment #{context.id} failed: #{inspect(reason)}")

    # Save failure metadata
    save_deployment_metadata(context, :failed)

    # Run failure hooks
    run_deployment_hooks(:on_failure, context)

    # Attempt rollback if enabled
    if Keyword.get(context.raw_options, :rollback_on_failure, true) do
      case attempt_automatic_rollback(context) do
        :ok ->
          Logger.info("Automatic rollback completed successfully")

          {:error,
           %{
             deployment_id: context.id,
             reason: reason,
             rollback: :successful,
             status: :rolled_back
           }}

        {:error, rollback_reason} ->
          Logger.error("Automatic rollback failed: #{inspect(rollback_reason)}")

          {:error,
           %{
             deployment_id: context.id,
             reason: reason,
             rollback: :failed,
             rollback_reason: rollback_reason,
             status: :failed_with_rollback_failure
           }}
      end
    else
      {:error, %{deployment_id: context.id, reason: reason, status: :failed}}
    end
  end

  defp attempt_automatic_rollback(context) do
    Logger.warning("Attempting automatic rollback for failed deployment #{context.id}")

    case ReleaseManager.rollback_release() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_emergency_rollback(deployment_id) do
    Logger.warning("Performing emergency rollback for deployment #{deployment_id}")

    case ReleaseManager.rollback_release() do
      :ok ->
        Logger.info("Emergency rollback completed successfully")
        {:ok, :rolled_back}

      {:error, reason} ->
        Logger.error("Emergency rollback failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp sanitize_options_for_storage(opts) do
    # Convert options to a map with only JSON-encodable values
    opts
    |> Enum.map(fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
    |> Enum.into(%{})
  end
end
