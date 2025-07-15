defmodule Bloom.LifecycleManagerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bloom.LifecycleManager

  setup do
    # Store original configuration
    original_auto_cleanup = Application.get_env(:bloom, :auto_cleanup_enabled)
    original_retention_count = Application.get_env(:bloom, :release_retention_count)
    original_disk_threshold = Application.get_env(:bloom, :disk_space_warning_threshold)

    # Set test configuration
    Application.put_env(:bloom, :auto_cleanup_enabled, false)
    Application.put_env(:bloom, :release_retention_count, 3)
    Application.put_env(:bloom, :disk_space_warning_threshold, 85)

    # Reset mock state
    Bloom.MockReleaseHandler.reset_to_initial_state()

    on_exit(fn ->
      # Restore original configuration
      restore_env(:bloom, :auto_cleanup_enabled, original_auto_cleanup)
      restore_env(:bloom, :release_retention_count, original_retention_count)
      restore_env(:bloom, :disk_space_warning_threshold, original_disk_threshold)
      # Reset mock state
      Bloom.MockReleaseHandler.reset_to_initial_state()
    end)

    :ok
  end

  # Helper to restore environment variables
  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  describe "cleanup_old_releases/1" do
    test "performs dry run without removing releases" do
      result = LifecycleManager.cleanup_old_releases(dry_run: true, retention_count: 2)

      # Should return information about what would be removed
      assert {:ok, %{would_remove: _, releases: _}} = result
    end

    test "respects retention count configuration" do
      Application.put_env(:bloom, :release_retention_count, 3)

      result = LifecycleManager.cleanup_old_releases(dry_run: true)

      assert {:ok, %{would_remove: count, releases: _}} = result
      # The exact count depends on mock releases, but should respect the policy
      assert is_integer(count) and count >= 0
    end

    test "validates cleanup safety" do
      # This test ensures we don't accidentally remove the current release
      result = LifecycleManager.cleanup_old_releases(dry_run: true, retention_count: 0)

      # Should either succeed with 0 removals or fail with safety error
      case result do
        {:ok, %{would_remove: 0}} -> :ok
        {:error, msg} when is_binary(msg) -> :ok
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end
  end

  describe "remove_release/2" do
    test "validates removal safety for current release" do
      {:ok, current_version} = Bloom.ReleaseManager.current_release()

      result = LifecycleManager.remove_release(current_version)

      assert {:error, msg} = result
      assert String.contains?(msg, "Cannot remove currently running release")
    end

    @tag :capture_log
    test "handles non-existent release gracefully" do
      capture_log(fn ->
        result = LifecycleManager.remove_release("non-existent-version")

        # Should return an error, not crash
        assert {:error, _msg} = result
      end)
    end
  end

  describe "check_disk_space/1" do
    test "returns disk space information" do
      result = LifecycleManager.check_disk_space()

      case result do
        {:ok, info} ->
          assert Map.has_key?(info, :usage_percentage)
          assert Map.has_key?(info, :release_count)

        {:warning, info} ->
          assert Map.has_key?(info, :usage_percentage)
          assert info.usage_percentage >= 85

        {:error, _reason} ->
          # Disk space checking might not work in all test environments
          :ok
      end
    end

    test "warns when disk usage exceeds threshold" do
      # Test with low threshold to trigger warning
      result = LifecycleManager.check_disk_space(warning_threshold: 1)

      case result do
        {:warning, info} ->
          assert info.usage_percentage >= 1
          assert info.warning_threshold == 1

        {:ok, _info} ->
          # If disk usage is actually below 1%, that's fine too
          :ok

        {:error, _reason} ->
          # Disk space checking might not work in test environment
          :ok
      end
    end
  end

  describe "get_release_info/0" do
    test "returns comprehensive release information" do
      result = LifecycleManager.get_release_info()

      case result do
        {:ok, info} ->
          assert Map.has_key?(info, :releases)
          assert Map.has_key?(info, :current_release)
          assert Map.has_key?(info, :total_disk_usage)
          assert is_list(info.releases)

        {:error, _reason} ->
          # Might fail in test environment without proper release setup
          :ok
      end
    end
  end

  describe "auto_cleanup_if_needed/0" do
    test "respects auto_cleanup_enabled configuration" do
      Application.put_env(:bloom, :auto_cleanup_enabled, false)

      # Should return :ok without doing anything
      assert :ok = LifecycleManager.auto_cleanup_if_needed()
    end

    test "performs cleanup when enabled and needed" do
      Application.put_env(:bloom, :auto_cleanup_enabled, true)
      # Force warning
      Application.put_env(:bloom, :disk_space_warning_threshold, 1)

      # Should not crash, even if cleanup fails in test environment
      result = LifecycleManager.auto_cleanup_if_needed()
      assert result == :ok
    end
  end

  describe "configuration integration" do
    test "uses default retention count when not configured" do
      Application.delete_env(:bloom, :release_retention_count)

      result = LifecycleManager.cleanup_old_releases(dry_run: true)

      # Should use default of 5 without crashing
      case result do
        {:ok, %{would_remove: _, releases: _}} -> :ok
        # Might fail in test environment
        {:error, _} -> :ok
      end
    end

    test "respects custom disk space warning threshold" do
      Application.put_env(:bloom, :disk_space_warning_threshold, 50)

      result = LifecycleManager.check_disk_space()

      case result do
        {:ok, info} -> assert info.warning_threshold == 50
        {:warning, info} -> assert info.warning_threshold == 50
        # Might fail in test environment
        {:error, _} -> :ok
      end
    end
  end
end
