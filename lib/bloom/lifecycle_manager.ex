defmodule Bloom.LifecycleManager do
  @moduledoc """
  Manages the lifecycle of releases including cleanup, retention policies, and disk space monitoring.

  This module provides automated cleanup of old releases, configurable retention policies,
  and monitoring of disk space usage to maintain a healthy release environment.
  """

  require Logger

  @doc """
  Clean up old releases based on retention policy.

  Options:
  - `:retention_count` - Number of releases to keep (default: from config or 5)
  - `:dry_run` - Show what would be removed without actually removing (default: false)
  - `:force` - Remove releases even if they're marked as permanent (default: false)
  """
  def cleanup_old_releases(opts \\ []) do
    retention_count =
      Keyword.get(opts, :retention_count) ||
        Application.get_env(:bloom, :release_retention_count, 5)

    dry_run = Keyword.get(opts, :dry_run, false)
    force = Keyword.get(opts, :force, false)

    with {:ok, releases} <- get_all_releases(),
         {:ok, current_release} <- get_current_release_info(),
         cleanup_candidates <-
           identify_cleanup_candidates(releases, current_release, retention_count, force),
         :ok <- validate_cleanup_safety(cleanup_candidates, current_release) do
      if dry_run do
        log_dry_run_results(cleanup_candidates)
        {:ok, %{would_remove: length(cleanup_candidates), releases: cleanup_candidates}}
      else
        perform_cleanup(cleanup_candidates)
      end
    else
      error -> error
    end
  end

  @doc """
  Remove a specific release version.

  This will only remove releases that are not currently running and not marked as permanent.
  """
  def remove_release(version, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    with {:ok, current_release} <- get_current_release_info(),
         :ok <- validate_removal_safety(version, current_release, force) do
      Logger.info("Removing release #{version}")

      case Bloom.ReleaseHandler.remove_release(version) do
        :ok ->
          Logger.info("Successfully removed release #{version}")
          :ok

        {:error, reason} ->
          interpreted_error =
            Bloom.ErrorInterpreter.interpret_error(
              {:error, reason},
              %{operation: :remove, version: version}
            )

          error_message = Bloom.ErrorInterpreter.format_error(interpreted_error)
          Logger.error("Failed to remove release #{version}: #{error_message}")
          {:error, error_message}
      end
    else
      error -> error
    end
  end

  @doc """
  Check disk space usage and warn if approaching limits.

  Returns disk space information and warnings.
  """
  def check_disk_space(opts \\ []) do
    warning_threshold =
      Keyword.get(opts, :warning_threshold) ||
        Application.get_env(:bloom, :disk_space_warning_threshold, 85)

    with {:ok, disk_info} <- get_disk_usage(),
         {:ok, release_info} <- get_release_disk_usage() do
      usage_percentage = calculate_usage_percentage(disk_info)

      result = %{
        total_space: disk_info.total,
        available_space: disk_info.available,
        used_space: disk_info.used,
        usage_percentage: usage_percentage,
        release_space_used: release_info.total_size,
        release_count: release_info.count,
        warning_threshold: warning_threshold
      }

      if usage_percentage >= warning_threshold do
        Logger.warning(
          "Disk space usage is #{usage_percentage}% (threshold: #{warning_threshold}%)"
        )

        {:warning, result}
      else
        {:ok, result}
      end
    else
      error -> error
    end
  end

  @doc """
  Get comprehensive information about all releases and their disk usage.
  """
  def get_release_info do
    with {:ok, releases} <- get_all_releases(),
         {:ok, current_release} <- get_current_release_info(),
         {:ok, disk_usage} <- get_release_disk_usage() do
      release_details =
        Enum.map(releases, fn {name, version, _libs, status} ->
          %{
            name: to_string(name),
            version: to_string(version),
            status: status,
            is_current: to_string(version) == current_release.version,
            estimated_size: estimate_release_size(to_string(version))
          }
        end)

      {:ok,
       %{
         releases: release_details,
         current_release: current_release,
         total_disk_usage: disk_usage,
         cleanup_candidates: identify_cleanup_candidates(releases, current_release, 5, false)
       }}
    else
      error -> error
    end
  end

  @doc """
  Perform automatic cleanup if disk space usage exceeds threshold.

  This is typically called automatically during deployments.
  """
  def auto_cleanup_if_needed do
    if Application.get_env(:bloom, :auto_cleanup_enabled, true) do
      case check_disk_space() do
        {:warning, disk_info} ->
          Logger.info(
            "Disk space usage high (#{disk_info.usage_percentage}%), performing automatic cleanup"
          )

          cleanup_old_releases()

        {:ok, _disk_info} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not check disk space for auto cleanup: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  # Private functions

  defp get_all_releases do
    case Bloom.ReleaseHandler.which_releases() do
      releases when is_list(releases) ->
        {:ok, releases}

      error ->
        {:error, {:failed_to_get_releases, error}}
    end
  end

  defp get_current_release_info do
    case Bloom.ReleaseManager.current_release() do
      {:ok, version} -> {:ok, %{version: version}}
      error -> error
    end
  end

  defp identify_cleanup_candidates(releases, current_release, retention_count, force) do
    releases
    |> Enum.map(fn {name, version, _libs, status} ->
      %{
        name: to_string(name),
        version: to_string(version),
        status: status,
        is_current: to_string(version) == current_release.version
      }
    end)
    |> Enum.reject(fn release -> release.is_current end)
    |> Enum.reject(fn release -> release.status == :permanent and not force end)
    |> Enum.sort_by(fn release -> release.version end, :desc)
    # Keep retention_count - 1 old releases (plus current)
    |> Enum.drop(retention_count - 1)
  end

  defp validate_cleanup_safety(cleanup_candidates, current_release) do
    # Ensure we're not removing the current release
    current_in_candidates =
      Enum.any?(cleanup_candidates, fn r ->
        r.version == current_release.version
      end)

    if current_in_candidates do
      {:error, "Cannot remove current release during cleanup"}
    else
      :ok
    end
  end

  defp validate_removal_safety(version, current_release, force) do
    cond do
      version == current_release.version ->
        {:error, "Cannot remove currently running release"}

      not force and is_permanent_release?(version) ->
        {:error, "Cannot remove permanent release without force option"}

      true ->
        :ok
    end
  end

  defp is_permanent_release?(version) do
    case get_all_releases() do
      {:ok, releases} ->
        Enum.any?(releases, fn {_name, v, _libs, status} ->
          to_string(v) == version and status == :permanent
        end)

      _ ->
        false
    end
  end

  defp log_dry_run_results([]) do
    Logger.info("No releases would be removed")
  end

  defp log_dry_run_results(candidates) do
    Logger.info("Would remove #{length(candidates)} releases:")

    Enum.each(candidates, fn release ->
      Logger.info("  - #{release.version} (#{release.status})")
    end)
  end

  defp perform_cleanup([]) do
    Logger.info("No old releases to clean up")
    {:ok, %{removed: 0, releases: []}}
  end

  defp perform_cleanup(candidates) do
    Logger.info("Cleaning up #{length(candidates)} old releases")

    results =
      Enum.map(candidates, fn release ->
        case remove_release(release.version) do
          :ok -> {:ok, release.version}
          {:error, reason} -> {:error, {release.version, reason}}
        end
      end)

    successes = Enum.filter(results, &match?({:ok, _}, &1))
    failures = Enum.filter(results, &match?({:error, _}, &1))

    if length(failures) > 0 do
      Logger.warning("Some releases failed to be removed: #{inspect(failures)}")
    end

    Logger.info("Cleaned up #{length(successes)} old releases successfully")

    {:ok,
     %{
       removed: length(successes),
       failed: length(failures),
       releases: Enum.map(successes, fn {:ok, version} -> version end),
       errors: failures
     }}
  end

  defp get_disk_usage do
    try do
      releases_dir = Application.get_env(:bloom, :releases_dir, "releases")
      command_fn = Application.get_env(:bloom, :disk_usage_command, 
        fn releases_dir -> {"df", ["-h", releases_dir], []} end)
      
      {cmd, args, opts} = command_fn.(releases_dir)

      case System.cmd(cmd, args, opts) do
        {output, 0} ->
          parse_df_output(output)

        {_output, _exit_code} ->
          {:error, :df_command_failed}
      end
    rescue
      _ -> {:error, :disk_check_unavailable}
    end
  end

  defp parse_df_output(output) do
    lines = String.split(output, "\n")

    # Second line contains the data
    case Enum.at(lines, 1) do
      nil ->
        {:error, :invalid_df_output}

      data_line ->
        parts = String.split(data_line)

        if length(parts) >= 4 do
          {:ok,
           %{
             total: Enum.at(parts, 1),
             used: Enum.at(parts, 2),
             available: Enum.at(parts, 3),
             mount_point: Enum.at(parts, 5) || Enum.at(parts, 0)
           }}
        else
          {:error, :invalid_df_format}
        end
    end
  end

  defp calculate_usage_percentage(%{total: total, used: used}) do
    # Convert human readable format to bytes for calculation
    total_bytes = parse_size_string(total)
    used_bytes = parse_size_string(used)

    if total_bytes > 0 do
      round(used_bytes / total_bytes * 100)
    else
      0
    end
  end

  defp parse_size_string(size_str) do
    # Simple parser for df output like "10G", "500M", etc.
    # This is a basic implementation
    case Regex.run(~r/^(\d+(?:\.\d+)?)([KMGT]?)/, size_str) do
      [_, number_str, unit] ->
        number = 
          if String.contains?(number_str, ".") do
            String.to_float(number_str)
          else
            String.to_integer(number_str) * 1.0
          end

        multiplier =
          case unit do
            "K" -> 1024
            "M" -> 1024 * 1024
            "G" -> 1024 * 1024 * 1024
            "T" -> 1024 * 1024 * 1024 * 1024
            _ -> 1
          end

        round(number * multiplier)

      _ ->
        0
    end
  end

  defp get_release_disk_usage do
    try do
      releases_dir = Application.get_env(:bloom, :releases_dir, "releases")
      command_fn = Application.get_env(:bloom, :release_disk_usage_command,
        fn releases_dir -> {"du", ["-sh", releases_dir], []} end)
      
      {cmd, args, opts} = command_fn.(releases_dir)

      case System.cmd(cmd, args, opts) do
        {output, 0} ->
          [size_info | _] = String.split(output, "\n")
          [size | _] = String.split(size_info, "\t")

          {:ok,
           %{
             total_size: String.trim(size),
             count: count_releases()
           }}

        {_output, _exit_code} ->
          {:error, :du_command_failed}
      end
    rescue
      _ ->
        {:ok, %{total_size: "unknown", count: 0}}
    end
  end

  defp count_releases do
    case get_all_releases() do
      {:ok, releases} -> length(releases)
      _ -> 0
    end
  end

  defp estimate_release_size(_version) do
    # This is a rough estimate - in practice you might want to 
    # actually measure the release directory size
    "~50MB"
  end
end
