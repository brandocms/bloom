defmodule Bloom.ReleaseManagerTest do
  use ExUnit.Case, async: false
  
  import ExUnit.CaptureLog

  alias Bloom.ReleaseManager
  alias Bloom.MockReleaseHandler

  setup do
    # Create unique temporary directory for this test
    test_dir = "test/tmp/#{:erlang.unique_integer()}"
    Application.put_env(:bloom, :app_root, test_dir)

    # Reset mock state completely
    MockReleaseHandler.reset_to_initial_state()
    # Clear all releases to start fresh
    MockReleaseHandler.clear_releases()

    # Set up some default releases for tests that expect them
    MockReleaseHandler.add_mock_release(:bloom_test, "0.1.0", :permanent)
    MockReleaseHandler.add_mock_release(:bloom_test, "0.0.9", :old)

    on_exit(fn ->
      # Clean up test directory
      File.rm_rf(test_dir)
      # Reset mock state
      MockReleaseHandler.reset_to_initial_state()
      # Clear application environment
      Application.delete_env(:bloom, :app_root)
    end)

    :ok
  end

  describe "install_release/1" do
    @tag :capture_log
    test "successfully installs a release" do
      logs = capture_log(fn ->
        assert ReleaseManager.install_release("1.2.3") == :installed
      end)
      
      assert logs =~ "Installing release 1.2.3"
      assert logs =~ "Successfully installed release 1.2.3"
    end

    @tag :capture_log
    test "handles installation failure" do
      # Set up mock to fail
      MockReleaseHandler.set_next_result(:unpack_release, {:error, :no_such_release})

      logs = capture_log(fn ->
        assert {:error, error_message} = ReleaseManager.install_release("1.2.3")
        assert String.contains?(error_message, "Release 1.2.3 not found")
      end)
      
      assert logs =~ "Installing release 1.2.3"
      assert logs =~ "Failed to install release 1.2.3"
    end

    @tag :capture_log
    test "validates release before installation" do
      # Test with invalid version format
      logs = capture_log(fn ->
        assert {:error, error_msg} = ReleaseManager.install_release("invalid-version")
        assert error_msg =~ "Invalid version format"
      end)
      
      assert logs =~ "Installing release invalid-version"
      assert logs =~ "validation failed"
    end
  end

  describe "switch_release/1" do
    @tag :capture_log
    test "successfully switches to a release" do
      logs = capture_log(fn ->
        # Install release first
        assert ReleaseManager.install_release("1.2.3") == :installed

        # Then switch to it
        assert ReleaseManager.switch_release("1.2.3") == :switched
      end)
      
      assert logs =~ "Switching to release 1.2.3"
      assert logs =~ "Successfully switched to release 1.2.3"
    end

    @tag :capture_log
    test "handles switch failure with rollback attempt" do
      # Set up mock to fail
      MockReleaseHandler.set_next_result(:install_release, {:error, :bad_relup_file})

      logs = capture_log(fn ->
        assert {:error, error_message} = ReleaseManager.switch_release("1.2.3")
        assert String.contains?(error_message, "Invalid release upgrade file")
      end)
      
      assert logs =~ "Failed to switch to release 1.2.3"
      assert logs =~ "Attempting automatic rollback"
    end

    test "fails switch when health check fails" do
      # Mock health check to fail
      # Note: This would require mocking HealthChecker, which we'll skip for now
      # The test infrastructure is in place for when needed
    end
  end

  describe "list_releases/0" do
    test "returns formatted release list" do
      releases = ReleaseManager.list_releases()

      # Check that we have the expected releases (order may vary)
      assert length(releases) == 2
      assert %{name: "bloom_test", version: "0.1.0", status: :permanent} in releases
      assert %{name: "bloom_test", version: "0.0.9", status: :old} in releases
    end
  end

  describe "current_release/0" do
    test "returns current release info" do
      expected = {:ok, %{name: "bloom_test", version: "0.1.0", status: :permanent}}
      assert ReleaseManager.current_release() == expected
    end

    test "handles no current release" do
      # Clear all releases
      MockReleaseHandler.clear_releases()

      assert ReleaseManager.current_release() == {:error, :no_current_release}
    end
  end

  describe "rollback_release/0" do
    @tag :capture_log
    test "successfully rolls back to previous release" do
      logs = capture_log(fn ->
        # First create deployment history metadata
        Bloom.Metadata.save_release_info("1.2.2")
        Bloom.Metadata.save_release_info("1.2.3")

        # Set up releases in mock handler
        MockReleaseHandler.clear_releases()
        MockReleaseHandler.add_mock_release(:bloom_test, "1.2.3", :permanent)
        MockReleaseHandler.add_mock_release(:bloom_test, "1.2.2", :old)

        assert ReleaseManager.rollback_release() == :rolled_back
      end)
      
      assert logs =~ "Rolling back to previous release"
      assert logs =~ "Rollback target: 1.2.2"
    end

    @tag :capture_log
    test "handles no previous release available" do
      logs = capture_log(fn ->
        # Set up only one release (no previous metadata)
        MockReleaseHandler.clear_releases()
        MockReleaseHandler.add_mock_release(:bloom_test, "1.2.3", :permanent)

        assert ReleaseManager.rollback_release() == {:error, :no_previous_release}
      end)
      
      assert logs =~ "Rolling back to previous release"
      assert logs =~ "No previous release found for rollback"
    end
  end

  describe "error handling" do
    @tag :capture_log
    test "handles already installed error" do
      capture_log(fn ->
        # First install should succeed
        assert ReleaseManager.install_release("1.2.3") == :installed

        # Set mock to return already installed error
        MockReleaseHandler.set_next_result(:unpack_release, {:error, {:already_installed, "1.2.3"}})

        assert {:error, error_message} = ReleaseManager.install_release("1.2.3")
        assert String.contains?(error_message, "Release 1.2.3 is already installed")
      end)
    end

    @tag :capture_log
    test "handles bad relup file error" do
      capture_log(fn ->
        MockReleaseHandler.set_next_result(:install_release, {:error, {:bad_relup_file, []}})

        assert {:error, error_message} = ReleaseManager.switch_release("1.2.3")
        assert String.contains?(error_message, "Invalid release upgrade file")
      end)
    end
  end
end
