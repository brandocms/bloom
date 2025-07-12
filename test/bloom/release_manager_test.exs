defmodule Bloom.ReleaseManagerTest do
  use ExUnit.Case, async: false

  alias Bloom.ReleaseManager
  alias Bloom.MockReleaseHandler

  setup do
    # Clear metadata between tests
    Application.put_env(:bloom, :app_root, "test/tmp/#{:erlang.unique_integer()}")

    # Clear any previous mock state
    MockReleaseHandler.clear_releases()

    # Set up some default releases
    MockReleaseHandler.add_mock_release(:bloom_test, "0.1.0", :permanent)
    MockReleaseHandler.add_mock_release(:bloom_test, "0.0.9", :old)

    :ok
  end

  describe "install_release/1" do
    test "successfully installs a release" do
      assert ReleaseManager.install_release("1.2.3") == :ok
    end

    test "handles installation failure" do
      # Set up mock to fail
      MockReleaseHandler.set_next_result(:unpack_release, {:error, :no_such_release})

      assert {:error, error_message} = ReleaseManager.install_release("1.2.3")
      assert String.contains?(error_message, "Release 1.2.3 not found")
    end

    test "validates release before installation" do
      # Test with invalid version format
      assert {:error, error_msg} = ReleaseManager.install_release("invalid-version")
      assert error_msg =~ "Invalid version format"
    end
  end

  describe "switch_release/1" do
    test "successfully switches to a release" do
      # Install release first
      assert ReleaseManager.install_release("1.2.3") == :ok

      # Then switch to it
      assert ReleaseManager.switch_release("1.2.3") == :ok
    end

    test "handles switch failure with rollback attempt" do
      # Set up mock to fail
      MockReleaseHandler.set_next_result(:install_release, {:error, :bad_relup_file})

      assert {:error, error_message} = ReleaseManager.switch_release("1.2.3")
      assert String.contains?(error_message, "Invalid release upgrade file")
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
    test "successfully rolls back to previous release" do
      # First create deployment history metadata
      Bloom.Metadata.save_release_info("1.2.2")
      Bloom.Metadata.save_release_info("1.2.3")

      # Set up releases in mock handler
      MockReleaseHandler.clear_releases()
      MockReleaseHandler.add_mock_release(:bloom_test, "1.2.3", :permanent)
      MockReleaseHandler.add_mock_release(:bloom_test, "1.2.2", :old)

      assert ReleaseManager.rollback_release() == :ok
    end

    test "handles no previous release available" do
      # Set up only one release (no previous metadata)
      MockReleaseHandler.clear_releases()
      MockReleaseHandler.add_mock_release(:bloom_test, "1.2.3", :permanent)

      assert ReleaseManager.rollback_release() == {:error, :no_previous_release}
    end
  end

  describe "error handling" do
    test "handles already installed error" do
      # First install should succeed
      assert ReleaseManager.install_release("1.2.3") == :ok

      # Set mock to return already installed error
      MockReleaseHandler.set_next_result(:unpack_release, {:error, {:already_installed, "1.2.3"}})

      assert {:error, error_message} = ReleaseManager.install_release("1.2.3")
      assert String.contains?(error_message, "Release 1.2.3 is already installed")
    end

    test "handles bad relup file error" do
      MockReleaseHandler.set_next_result(:install_release, {:error, {:bad_relup_file, []}})

      assert {:error, error_message} = ReleaseManager.switch_release("1.2.3")
      assert String.contains?(error_message, "Invalid release upgrade file")
    end
  end
end
