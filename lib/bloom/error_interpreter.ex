defmodule Bloom.ErrorInterpreter do
  @moduledoc """
  Interprets Erlang :release_handler errors into actionable user messages.

  This module transforms low-level Erlang error tuples into human-readable
  messages with specific guidance on how to resolve the issues.
  """

  require Logger

  @doc """
  Interpret a :release_handler error into a user-friendly message.

  Returns a tuple with the interpreted error message and optional suggestions.
  """
  def interpret_error(error, context \\ %{})

  # Release installation errors
  def interpret_error({:error, {:already_installed, version}}, context) do
    suggestions = [
      "Use switch_release/1 instead of install_release/1",
      "Remove the existing release first with remove_release/1",
      "Check if you intended to switch to this version"
    ]

    {
      "Release #{version} is already installed",
      suggestions,
      add_context(context, %{error_type: :already_installed, version: version})
    }
  end

  def interpret_error({:error, :no_such_release}, context) do
    version = Map.get(context, :version, "unknown")

    suggestions = [
      "Verify the release package was uploaded correctly",
      "Check that the release version exists in the releases directory",
      "Ensure release was unpacked with unpack_release/1",
      "Verify release version spelling and format"
    ]

    {
      "Release #{version} not found",
      suggestions,
      add_context(context, %{error_type: :no_such_release})
    }
  end

  def interpret_error({:error, {:bad_relup_file, reason}}, context) do
    suggestions = [
      "This error indicates hot upgrade issues - Bloom uses cold restarts",
      "Try using switch_release/1 instead of install_release/1",
      "Verify the release was built correctly",
      "Check for version compatibility issues"
    ]

    {
      "Invalid release upgrade file: #{inspect(reason)}",
      suggestions,
      add_context(context, %{error_type: :bad_relup_file, reason: reason})
    }
  end

  def interpret_error({:error, :bad_relup_file}, context) do
    interpret_error({:error, {:bad_relup_file, "unknown"}}, context)
  end

  # Health check and validation errors
  def interpret_error({:error, :health_check_failed}, context) do
    suggestions = [
      "Check application logs for health check failures",
      "Verify all required services are running",
      "Review custom health checks registered with Bloom.HealthChecker",
      "Consider increasing health check timeout if checks are slow"
    ]

    {
      "Post-switch health checks failed",
      suggestions,
      add_context(context, %{error_type: :health_check_failed})
    }
  end

  def interpret_error({:error, :application_unhealthy}, context) do
    suggestions = [
      "Check if the application started successfully",
      "Review application startup logs",
      "Verify database connections and external dependencies",
      "Check system resources (memory, CPU, disk space)"
    ]

    {
      "Application failed health checks during deployment",
      suggestions,
      add_context(context, %{error_type: :application_unhealthy})
    }
  end

  # Resource and system errors
  def interpret_error({:error, :high_process_usage}, context) do
    suggestions = [
      "Check system process limit with 'ulimit -u'",
      "Review application for process leaks",
      "Consider increasing system process limits",
      "Check for stuck or hanging processes"
    ]

    {
      "System process usage is too high for safe deployment",
      suggestions,
      add_context(context, %{error_type: :high_process_usage})
    }
  end

  def interpret_error({:error, :invalid_memory_info}, context) do
    suggestions = [
      "System memory information could not be retrieved",
      "Check system monitoring tools",
      "Verify /proc/meminfo accessibility on Linux systems",
      "Consider disabling memory checks if running in constrained environments"
    ]

    {
      "Unable to retrieve system memory information",
      suggestions,
      add_context(context, %{error_type: :invalid_memory_info})
    }
  end

  # Database and migration errors
  def interpret_error({:error, {:migration_failed, reason}}, context) do
    suggestions = [
      "Review database migration logs for specific errors",
      "Check database connectivity and permissions",
      "Verify migration files are valid",
      "Consider running migrations manually to diagnose issues",
      "Check if database schema conflicts exist"
    ]

    {
      "Database migration failed: #{inspect(reason)}",
      suggestions,
      add_context(context, %{error_type: :migration_failed, reason: reason})
    }
  end

  def interpret_error({:error, {:backup_required, reason}}, context) do
    suggestions = [
      "Database backup creation failed but is required",
      "Check database connectivity and permissions",
      "Verify backup directory exists and is writable",
      "Check disk space in backup location",
      "Review backup configuration settings"
    ]

    {
      "Required database backup failed: #{inspect(reason)}",
      suggestions,
      add_context(context, %{error_type: :backup_failed, reason: reason})
    }
  end

  # Rollback and recovery errors
  def interpret_error({:error, :no_previous_release}, context) do
    suggestions = [
      "No previous release available for rollback",
      "This might be the first deployment to this system",
      "Check release history with list_releases/0",
      "Consider deploying a known good version manually"
    ]

    {
      "No previous release found for rollback",
      suggestions,
      add_context(context, %{error_type: :no_previous_release})
    }
  end

  def interpret_error({:error, :no_current_release}, context) do
    suggestions = [
      "No release is currently running",
      "Check if the Erlang node is properly started",
      "Verify release_handler is available",
      "Check system startup logs for issues"
    ]

    {
      "No current release detected",
      suggestions,
      add_context(context, %{error_type: :no_current_release})
    }
  end

  def interpret_error({:error, :no_valid_rollback_target}, context) do
    suggestions = [
      "Cannot rollback: target version is same as current",
      "This can happen in rollback loops",
      "Check release history to verify available versions",
      "Consider manual intervention or deploying a specific version"
    ]

    {
      "No valid rollback target available",
      suggestions,
      add_context(context, %{error_type: :no_valid_rollback_target})
    }
  end

  # Configuration and validation errors
  def interpret_error({:error, {:exception, exception}}, context) do
    suggestions = [
      "An unexpected exception occurred during operation",
      "Review the full stack trace in logs",
      "Check for configuration issues",
      "Verify all dependencies are properly installed",
      "Consider reporting this as a bug if it persists"
    ]

    {
      "Unexpected exception: #{inspect(exception)}",
      suggestions,
      add_context(context, %{error_type: :exception, exception: exception})
    }
  end

  # Version format and compatibility errors
  def interpret_error({:error, msg}, context) when is_binary(msg) do
    cond do
      String.contains?(msg, "Invalid version format") ->
        suggestions = [
          "Use semantic versioning format: X.Y.Z or X.Y.Z-suffix",
          "Remove any 'v' prefix from version numbers",
          "Avoid using more than 3 version components",
          "Check version format documentation"
        ]

        {msg, suggestions, add_context(context, %{error_type: :invalid_version_format})}

      String.contains?(msg, "Release directory not found") ->
        suggestions = [
          "Verify the release was built and deployed correctly",
          "Check release directory permissions",
          "Ensure release path configuration is correct",
          "Verify file system accessibility"
        ]

        {msg, suggestions, add_context(context, %{error_type: :directory_not_found})}

      String.contains?(msg, "Cannot switch to the same version") ->
        suggestions = [
          "Target version is the same as currently running version",
          "Check current version with current_release/0",
          "Verify you intended to switch to this version",
          "Use install_release/1 if you need to reinstall the same version"
        ]

        {msg, suggestions, add_context(context, %{error_type: :same_version})}

      true ->
        # Generic string error
        {msg, [], add_context(context, %{error_type: :generic_string})}
    end
  end

  # Catch-all for unhandled errors
  def interpret_error(error, context) do
    Logger.warning("Unhandled error type in ErrorInterpreter: #{inspect(error)}")

    suggestions = [
      "This is an unrecognized error type",
      "Check the logs for more detailed information",
      "Verify your operation and try again",
      "Consider reporting this error if it persists"
    ]

    {
      "Release operation failed: #{inspect(error)}",
      suggestions,
      add_context(context, %{error_type: :unhandled, original_error: error})
    }
  end

  @doc """
  Format an interpreted error into a comprehensive error message.

  Options:
  - `:include_suggestions` - Include suggested remediation steps (default: true)
  - `:include_context` - Include error context information (default: false)
  - `:format` - Output format `:string` or `:map` (default: `:string`)
  """
  def format_error({message, suggestions, context}, opts \\ []) do
    include_suggestions = Keyword.get(opts, :include_suggestions, true)
    include_context = Keyword.get(opts, :include_context, false)
    format = Keyword.get(opts, :format, :string)

    case format do
      :string ->
        format_as_string(message, suggestions, context, include_suggestions, include_context)

      :map ->
        %{
          message: message,
          suggestions: if(include_suggestions, do: suggestions, else: []),
          context: if(include_context, do: context, else: %{})
        }
    end
  end

  @doc """
  Get detailed error information for logging and debugging.
  """
  def get_error_details({_message, _suggestions, context}) do
    context
  end

  # Private functions

  defp add_context(existing_context, new_context) do
    Map.merge(existing_context, new_context)
    |> Map.put(:timestamp, DateTime.utc_now())
    |> Map.put(:interpreter_version, "1.0.0")
  end

  defp format_as_string(message, suggestions, context, include_suggestions, include_context) do
    parts = [message]

    parts =
      if include_suggestions and length(suggestions) > 0 do
        suggestion_text =
          suggestions
          |> Enum.with_index(1)
          |> Enum.map(fn {suggestion, idx} -> "  #{idx}. #{suggestion}" end)
          |> Enum.join("\n")

        parts ++ ["\nSuggested actions:", suggestion_text]
      else
        parts
      end

    parts =
      if include_context and map_size(context) > 0 do
        context_info = "Context: #{inspect(context, pretty: true)}"
        parts ++ ["\n", context_info]
      else
        parts
      end

    Enum.join(parts, "\n")
  end
end
