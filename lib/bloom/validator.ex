defmodule Bloom.Validator do
  @moduledoc """
  Release validation and compatibility checking.

  Provides validation functions to ensure releases are safe to install
  and switch to, including compatibility checks and system requirements.
  """

  require Logger

  @doc """
  Validate a release before installation or switching.

  Runs a series of validation checks to ensure the release is safe
  to install or switch to.
  """
  def validate_release(version) when is_binary(version) do
    checks = 
      if Application.get_env(:bloom, :skip_file_checks, false) do
        # Skip file system checks when configured (e.g., in tests)
        [
          &check_version_format/1,
          &check_dependencies/1
        ]
      else
        [
          &check_version_format/1,
          &check_release_exists/1,
          &check_dependencies/1,
          &check_disk_space/1
        ]
      end

    run_validation_checks(version, checks)
  end

  @doc """
  Check compatibility between two release versions.

  Determines if switching from one version to another is safe,
  checking for breaking changes and required migrations.
  """
  def check_compatibility(from_version, to_version)
      when is_binary(from_version) and is_binary(to_version) do
    Logger.info("Checking compatibility: #{from_version} -> #{to_version}")

    with :ok <- check_version_progression(from_version, to_version),
         :ok <- check_breaking_changes(from_version, to_version),
         :ok <- check_migration_requirements(from_version, to_version) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Private Implementation

  defp run_validation_checks(version, checks) do
    Logger.info("Validating release #{version}")

    results = Enum.map(checks, fn check_fn -> check_fn.(version) end)

    case Enum.find(results, fn result -> result != :ok end) do
      nil ->
        Logger.info("Release #{version} validation passed")
        :ok

      error ->
        Logger.error("Release #{version} validation failed: #{inspect(error)}")
        error
    end
  end

  defp check_release_exists(version) do
    releases_dir = Application.get_env(:bloom, :releases_dir, "releases")
    release_path = Path.join([releases_dir, version])

    if File.exists?(release_path) do
      # Check for required files
      rel_file = Path.join([release_path, "#{get_app_name()}.rel"])
      tar_file = Path.join([release_path, "#{get_app_name()}.tar.gz"])

      cond do
        not File.exists?(rel_file) ->
          {:error, "Release file (.rel) not found for version #{version}"}

        not File.exists?(tar_file) ->
          {:error, "Release archive (.tar.gz) not found for version #{version}"}

        true ->
          :ok
      end
    else
      {:error, "Release directory not found for version #{version}"}
    end
  end

  defp check_version_format(version) do
    # Simple semantic version validation
    if Regex.match?(~r/^\d+\.\d+\.\d+(-\w+)?$/, version) do
      :ok
    else
      {:error, "Invalid version format: #{version}. Expected format: X.Y.Z or X.Y.Z-suffix"}
    end
  end

  defp check_dependencies(version) do
    # TODO: Implement dependency checking
    # This could:
    # - Parse the .rel file to check application dependencies
    # - Verify that required OTP version is compatible
    # - Check for conflicting application versions
    Logger.debug("Checking dependencies for release #{version}")
    :ok
  end

  defp check_disk_space(_version) do
    # Check available disk space
    case get_disk_space_info() do
      {:ok, available_mb} ->
        required_mb = Application.get_env(:bloom, :min_disk_space_mb, 100)

        if available_mb >= required_mb do
          :ok
        else
          {:error,
           "Insufficient disk space. Required: #{required_mb}MB, Available: #{available_mb}MB"}
        end

      {:error, reason} ->
        Logger.warning("Could not check disk space: #{inspect(reason)}")
        # Don't fail validation if we can't check disk space
        :ok
    end
  end

  defp check_version_progression(from_version, to_version) do
    # Basic check that we're not downgrading unintentionally
    case Version.compare(to_version, from_version) do
      :gt ->
        :ok

      :eq ->
        {:error, "Cannot switch to the same version"}

      :lt ->
        # Allow downgrades but warn
        Logger.warning("Switching to older version: #{from_version} -> #{to_version}")
        :ok
    end
  rescue
    Version.InvalidVersionError ->
      Logger.warning("Could not parse versions for comparison: #{from_version}, #{to_version}")
      # Allow if we can't parse versions
      :ok
  end

  defp check_breaking_changes(_from_version, _to_version) do
    # TODO: Implement breaking change detection
    # This could:
    # - Read release notes or changelog
    # - Check for known incompatibilities
    # - Validate application configuration changes
    :ok
  end

  defp check_migration_requirements(_from_version, _to_version) do
    # TODO: Implement migration requirement checking
    # This could:
    # - Check for database migrations
    # - Verify data format compatibility
    # - Check for required pre-switch operations
    :ok
  end

  defp get_app_name do
    # Get the main application name
    case Application.get_env(:bloom, :app_name) do
      nil ->
        # Try to infer from current application
        case Application.started_applications() do
          [app | _] when is_tuple(app) ->
            app |> elem(0) |> to_string()

          _ ->
            # Fallback
            "app"
        end

      app_name when is_atom(app_name) ->
        to_string(app_name)

      app_name when is_binary(app_name) ->
        app_name
    end
  end

  defp get_disk_space_info do
    try do
      # Get disk usage for current directory
      {output, 0} = System.cmd("df", ["-m", "."], stderr_to_stdout: true)

      lines = String.split(output, "\n", trim: true)

      case lines do
        [_header, data_line | _] ->
          # Parse df output: Filesystem 1M-blocks Used Available Use% Mounted
          [_filesystem, _total, _used, available | _] = String.split(data_line)
          available_mb = String.to_integer(available)
          {:ok, available_mb}

        _ ->
          {:error, :cannot_parse_df_output}
      end
    rescue
      _ -> {:error, :df_command_failed}
    end
  end
end
