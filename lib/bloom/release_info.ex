defmodule Bloom.ReleaseInfo do
  @moduledoc """
  Provides detailed information about releases by parsing .rel files and release metadata.

  This module extracts rich information from Erlang release files (.rel) to provide
  comprehensive details about releases including application versions, ERTS compatibility,
  dependencies, and other metadata.
  """

  require Logger

  @doc """
  Get detailed information about a specific release.

  Returns comprehensive metadata including:
  - Release name and version
  - ERTS version requirements
  - List of applications with versions
  - Application dependencies
  - Release description and metadata
  """
  def get_release_details(version) do
    with {:ok, rel_file_path} <- find_rel_file(version),
         {:ok, rel_content} <- parse_rel_file(rel_file_path),
         {:ok, app_details} <- get_application_details(rel_content.applications) do
      release_info = %{
        name: rel_content.name,
        version: rel_content.version,
        erts_version: rel_content.erts_version,
        applications: app_details,
        application_count: length(app_details),
        core_applications: get_core_applications(app_details),
        user_applications: get_user_applications(app_details),
        release_file_path: rel_file_path,
        parsed_at: DateTime.utc_now()
      }

      {:ok, release_info}
    else
      error -> error
    end
  end

  @doc """
  Get summary information about all available releases.

  Returns a list of release summaries with basic information parsed from .rel files.
  """
  def get_all_releases_info do
    case Bloom.ReleaseHandler.which_releases() do
      releases when is_list(releases) ->
        release_summaries =
          releases
          |> Enum.map(fn {name, version, _libs, status} ->
            version_string = to_string(version)

            case get_release_summary(version_string) do
              {:ok, summary} ->
                Map.merge(summary, %{
                  name: to_string(name),
                  version: version_string,
                  status: status
                })

              {:error, _reason} ->
                # Fallback to basic information if .rel file parsing fails
                %{
                  name: to_string(name),
                  version: version_string,
                  status: status,
                  erts_version: "unknown",
                  applications: [],
                  application_count: 0,
                  error: "Could not parse release file"
                }
            end
          end)

        {:ok, release_summaries}

      error ->
        {:error, {:failed_to_get_releases, error}}
    end
  end

  @doc """
  Compare two releases and show differences in applications and versions.
  """
  def compare_releases(version1, version2) do
    with {:ok, release1} <- get_release_details(version1),
         {:ok, release2} <- get_release_details(version2) do
      app_changes = compare_applications(release1.applications, release2.applications)
      erts_change = compare_erts_versions(release1.erts_version, release2.erts_version)

      comparison = %{
        from_version: version1,
        to_version: version2,
        erts_change: erts_change,
        application_changes: app_changes,
        summary: %{
          added_applications: length(app_changes.added),
          removed_applications: length(app_changes.removed),
          updated_applications: length(app_changes.updated),
          unchanged_applications: length(app_changes.unchanged)
        }
      }

      {:ok, comparison}
    else
      error -> error
    end
  end

  @doc """
  Validate release compatibility between versions.

  Checks for potential compatibility issues like ERTS version mismatches,
  missing dependencies, or incompatible application versions.
  """
  def validate_compatibility(from_version, to_version) do
    with {:ok, comparison} <- compare_releases(from_version, to_version) do
      issues = []

      # Check ERTS compatibility
      issues =
        if comparison.erts_change.compatible do
          issues
        else
          [create_issue(:erts_incompatible, comparison.erts_change) | issues]
        end

      # Check for removed core applications
      removed_core =
        Enum.filter(comparison.application_changes.removed, fn app ->
          app.type == :core
        end)

      issues =
        if length(removed_core) > 0 do
          [create_issue(:core_apps_removed, removed_core) | issues]
        else
          issues
        end

      # Check for major version bumps that might be breaking
      breaking_updates =
        Enum.filter(comparison.application_changes.updated, fn change ->
          is_major_version_change?(change.from_version, change.to_version)
        end)

      issues =
        if length(breaking_updates) > 0 do
          [create_issue(:potential_breaking_changes, breaking_updates) | issues]
        else
          issues
        end

      result = %{
        compatible: length(issues) == 0,
        issues: issues,
        warnings: generate_warnings(comparison),
        recommendations: generate_recommendations(comparison)
      }

      {:ok, result}
    else
      error -> error
    end
  end

  # Private functions

  defp get_release_summary(version) do
    case find_rel_file(version) do
      {:ok, rel_file_path} ->
        case parse_rel_file(rel_file_path) do
          {:ok, rel_content} ->
            {:ok,
             %{
               erts_version: rel_content.erts_version,
               application_count: length(rel_content.applications),
               applications:
                 Enum.map(rel_content.applications, fn {name, version} ->
                   %{name: to_string(name), version: to_string(version)}
                 end)
             }}

          error ->
            error
        end

      error ->
        error
    end
  end

  defp find_rel_file(version) do
    releases_dir = Application.get_env(:bloom, :releases_dir, "releases")

    # Try common patterns for .rel file locations
    possible_paths = [
      Path.join([releases_dir, version, "#{get_app_name()}.rel"]),
      Path.join([releases_dir, version, "#{version}.rel"]),
      Path.join([releases_dir, "#{version}.rel"]),
      Path.join([releases_dir, version, "release.rel"])
    ]

    case Enum.find(possible_paths, &File.exists?/1) do
      nil -> {:error, {:rel_file_not_found, version}}
      path -> {:ok, path}
    end
  end

  defp parse_rel_file(file_path) do
    try do
      case File.read(file_path) do
        {:ok, content} ->
          # Parse the Erlang term from the .rel file
          case Code.eval_string(content) do
            {{:release, {name, version}, {erts, erts_version}, applications}, _binding} ->
              {:ok,
               %{
                 name: to_string(name),
                 version: to_string(version),
                 erts: to_string(erts),
                 erts_version: to_string(erts_version),
                 applications: applications
               }}

            {other, _binding} ->
              {:error, {:invalid_rel_format, other}}
          end

        {:error, reason} ->
          {:error, {:file_read_error, reason}}
      end
    rescue
      error ->
        {:error, {:parse_error, error}}
    end
  end

  defp get_application_details(applications) do
    app_details =
      Enum.map(applications, fn
        {name, version} ->
          create_app_info(name, version, [])

        {name, version, type} ->
          create_app_info(name, version, type)
      end)

    {:ok, app_details}
  end

  defp create_app_info(name, version, type) do
    app_name = to_string(name)
    app_version = to_string(version)

    %{
      name: app_name,
      version: app_version,
      type: determine_app_type(app_name, type),
      description: get_app_description(app_name),
      dependencies: get_app_dependencies(app_name)
    }
  end

  defp determine_app_type(_app_name, type) when is_list(type) do
    cond do
      :permanent in type -> :permanent
      :transient in type -> :transient
      :temporary in type -> :temporary
      true -> :normal
    end
  end

  defp determine_app_type(app_name, _type) do
    # Categorize based on application name
    cond do
      app_name in ["kernel", "stdlib", "sasl"] -> :core
      app_name in ["erts"] -> :runtime
      String.starts_with?(app_name, "crypto") -> :crypto
      String.starts_with?(app_name, "ssl") -> :security
      true -> :user
    end
  end

  defp get_core_applications(applications) do
    Enum.filter(applications, fn app -> app.type == :core end)
  end

  defp get_user_applications(applications) do
    Enum.filter(applications, fn app -> app.type == :user end)
  end

  defp get_app_description(app_name) do
    # Try to get description from application spec
    try do
      case Application.spec(String.to_atom(app_name), :description) do
        nil -> "No description available"
        desc when is_list(desc) -> List.to_string(desc)
        desc -> to_string(desc)
      end
    rescue
      _ -> "No description available"
    end
  end

  defp get_app_dependencies(app_name) do
    # Try to get dependencies from application spec
    try do
      case Application.spec(String.to_atom(app_name), :applications) do
        nil -> []
        deps when is_list(deps) -> Enum.map(deps, &to_string/1)
        _ -> []
      end
    rescue
      _ -> []
    end
  end

  defp get_app_name do
    Application.get_env(:bloom, :app_name, "app")
  end

  defp compare_applications(apps1, apps2) do
    apps1_map = Map.new(apps1, fn app -> {app.name, app} end)
    apps2_map = Map.new(apps2, fn app -> {app.name, app} end)

    all_app_names =
      MapSet.union(
        MapSet.new(Map.keys(apps1_map)),
        MapSet.new(Map.keys(apps2_map))
      )

    {added, removed, updated, unchanged} =
      Enum.reduce(all_app_names, {[], [], [], []}, fn app_name,
                                                      {added, removed, updated, unchanged} ->
        case {Map.get(apps1_map, app_name), Map.get(apps2_map, app_name)} do
          {nil, app2} ->
            # Application added
            {[app2 | added], removed, updated, unchanged}

          {app1, nil} ->
            # Application removed
            {added, [app1 | removed], updated, unchanged}

          {app1, app2} when app1.version != app2.version ->
            # Application updated
            change = %{
              name: app_name,
              from_version: app1.version,
              to_version: app2.version,
              type: app1.type
            }

            {added, removed, [change | updated], unchanged}

          {app1, _app2} ->
            # Application unchanged
            {added, removed, updated, [app1 | unchanged]}
        end
      end)

    %{
      added: Enum.reverse(added),
      removed: Enum.reverse(removed),
      updated: Enum.reverse(updated),
      unchanged: Enum.reverse(unchanged)
    }
  end

  defp compare_erts_versions(erts1, erts2) do
    %{
      from: erts1,
      to: erts2,
      changed: erts1 != erts2,
      compatible: is_erts_compatible?(erts1, erts2)
    }
  end

  defp is_erts_compatible?(erts1, erts2) do
    # Basic compatibility check - same major version
    try do
      v1_parts = String.split(erts1, ".")
      v2_parts = String.split(erts2, ".")

      case {v1_parts, v2_parts} do
        {[maj1 | _], [maj2 | _]} -> maj1 == maj2
        _ -> false
      end
    rescue
      _ -> false
    end
  end

  defp is_major_version_change?(version1, version2) do
    try do
      v1_parts = String.split(version1, ".")
      v2_parts = String.split(version2, ".")

      case {v1_parts, v2_parts} do
        {[maj1 | _], [maj2 | _]} -> maj1 != maj2
        _ -> false
      end
    rescue
      _ -> false
    end
  end

  defp create_issue(type, data) do
    %{
      type: type,
      severity: get_issue_severity(type),
      description: get_issue_description(type, data),
      data: data
    }
  end

  defp get_issue_severity(:erts_incompatible), do: :error
  defp get_issue_severity(:core_apps_removed), do: :error
  defp get_issue_severity(:potential_breaking_changes), do: :warning

  defp get_issue_description(:erts_incompatible, erts_change) do
    "ERTS version incompatibility: #{erts_change.from} -> #{erts_change.to}"
  end

  defp get_issue_description(:core_apps_removed, removed_apps) do
    app_names = Enum.map(removed_apps, & &1.name)
    "Core applications removed: #{Enum.join(app_names, ", ")}"
  end

  defp get_issue_description(:potential_breaking_changes, breaking_updates) do
    app_names = Enum.map(breaking_updates, & &1.name)
    "Potential breaking changes in: #{Enum.join(app_names, ", ")}"
  end

  defp generate_warnings(comparison) do
    warnings = []

    # Warn about ERTS changes
    warnings =
      if comparison.erts_change.changed do
        [
          "ERTS version changed from #{comparison.erts_change.from} to #{comparison.erts_change.to}"
          | warnings
        ]
      else
        warnings
      end

    # Warn about removed applications
    warnings =
      if length(comparison.application_changes.removed) > 0 do
        removed_names = Enum.map(comparison.application_changes.removed, & &1.name)
        ["Applications removed: #{Enum.join(removed_names, ", ")}" | warnings]
      else
        warnings
      end

    Enum.reverse(warnings)
  end

  defp generate_recommendations(comparison) do
    recommendations = []

    # Recommend testing for major updates
    major_updates =
      Enum.filter(comparison.application_changes.updated, fn change ->
        is_major_version_change?(change.from_version, change.to_version)
      end)

    recommendations =
      if length(major_updates) > 0 do
        ["Test thoroughly due to major version updates in applications" | recommendations]
      else
        recommendations
      end

    # Recommend backup for ERTS changes
    recommendations =
      if comparison.erts_change.changed do
        ["Consider creating a system backup due to ERTS version change" | recommendations]
      else
        recommendations
      end

    Enum.reverse(recommendations)
  end
end
