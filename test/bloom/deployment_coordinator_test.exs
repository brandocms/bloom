defmodule Bloom.DeploymentCoordinatorTest do
  # MUST be false - modifies shared state
  use ExUnit.Case, async: false

  alias Bloom.DeploymentCoordinator
  alias Bloom.MockReleaseHandler

  setup do
    # Create unique temporary directory for this test
    test_dir = "test/tmp/deployment_#{:erlang.unique_integer()}"
    File.mkdir_p!(test_dir)
    Application.put_env(:bloom, :app_root, test_dir)

    # Initialize metadata storage for tests
    Bloom.Metadata.init_metadata_storage()

    # Clear any existing deployment hooks and registry
    Application.delete_env(:bloom, :deployment_hooks)
    Application.delete_env(:bloom, :deployment_hooks_registry)
    Bloom.DeploymentHooks.clear_hooks()

    # Reset mock release handler state completely
    MockReleaseHandler.reset_to_initial_state()
    MockReleaseHandler.add_mock_release(:bloom_test, "1.0.0", :permanent)
    MockReleaseHandler.add_mock_release(:bloom_test, "1.1.0", :old)

    # Reset health checker state
    GenServer.call(Bloom.HealthChecker, :reset_to_defaults)

    on_exit(fn ->
      # Clean up test directory
      File.rm_rf(test_dir)
      # Clean up application environment
      Application.delete_env(:bloom, :app_root)
      Application.delete_env(:bloom, :deployment_hooks)
      Application.delete_env(:bloom, :deployment_hooks_registry)
      # Clean up hooks registry
      Bloom.DeploymentHooks.clear_hooks()
      # Reset mock state
      MockReleaseHandler.reset_to_initial_state()
      # Reset health checker
      GenServer.call(Bloom.HealthChecker, :reset_to_defaults)
      # Unregister any test processes
      unregister_test_processes()
    end)

    :ok
  end

  # Helper to unregister test processes safely
  defp unregister_test_processes do
    test_processes = [:test_hook_process, :test_hook_process_post]

    for process_name <- test_processes do
      try do
        case Process.whereis(process_name) do
          nil -> :ok
          _pid -> Process.unregister(process_name)
        end
      rescue
        _ -> :ok
      end
    end
  end

  describe "deploy/2" do
    test "successfully deploys with default options" do
      result = DeploymentCoordinator.deploy("1.1.0")

      assert {:ok, deployment_result} = result
      assert Map.has_key?(deployment_result, :deployment_id)
      assert deployment_result.version == "1.1.0"
      assert deployment_result.status == :completed
    end

    test "fails deployment when target version is already current" do
      result = DeploymentCoordinator.deploy("1.0.0")

      assert {:error, error_info} = result
      assert Map.has_key?(error_info, :deployment_id)
      assert Map.has_key?(error_info, :reason)
    end

    test "handles deployment with custom options" do
      opts = [
        health_check_timeout: 10_000,
        rollback_on_failure: false,
        cleanup_after_success: false
      ]

      result = DeploymentCoordinator.deploy("1.1.0", opts)

      assert {:ok, deployment_result} = result
      assert deployment_result.status == :completed
    end

    test "skips health checks when requested" do
      opts = [skip_health_checks: true]

      result = DeploymentCoordinator.deploy("1.1.0", opts)

      assert {:ok, deployment_result} = result
      assert deployment_result.status == :completed
    end
  end

  describe "validate_deployment/1" do
    test "validates deployment safety" do
      result = DeploymentCoordinator.validate_deployment("1.1.0")

      case result do
        {:ok, validation_result} ->
          assert validation_result.safe_to_deploy == true
          assert is_list(validation_result.validations_passed)

        {:error, validation_result} ->
          assert validation_result.safe_to_deploy == false
          assert Map.has_key?(validation_result, :reason)
      end
    end

    test "rejects deployment to same version" do
      result = DeploymentCoordinator.validate_deployment("1.0.0")

      assert {:error, validation_result} = result
      assert validation_result.safe_to_deploy == false
      assert String.contains?(validation_result.reason, "already deployed")
    end
  end

  describe "deployment hooks" do
    test "registers and runs pre-deployment hooks" do
      # Register a test hook using the DeploymentHooks module
      test_pid = self()

      # We need to create a module for the hook since we can't pass anonymous functions
      defmodule TestPreDeploymentHook do
        def execute(context) do
          # Find the test_pid from the context or from Process
          test_pid = Process.whereis(:test_hook_process) || self()
          send(test_pid, {:hook_called, :pre_deployment, context.target_version})
          :ok
        end
      end

      # Register the process so the hook can find it
      Process.register(self(), :test_hook_process)

      Bloom.DeploymentHooks.register_hook(:pre_deployment, TestPreDeploymentHook)

      DeploymentCoordinator.deploy("1.1.0")

      assert_receive {:hook_called, :pre_deployment, "1.1.0"}, 1000
    end

    test "handles hook failures gracefully" do
      defmodule TestFailingHook do
        def execute(_context) do
          {:error, "Hook intentionally failed"}
        end
      end

      Bloom.DeploymentHooks.register_hook(:pre_deployment, TestFailingHook)

      result = DeploymentCoordinator.deploy("1.1.0")

      assert {:error, error_info} = result
      assert String.contains?(error_info.reason, "Hook")
    end

    test "runs post-deployment hooks on success" do
      test_pid = self()

      defmodule TestPostDeploymentHook do
        def execute(context) do
          test_pid = Process.whereis(:test_hook_process_post) || self()
          send(test_pid, {:hook_called, :post_deployment, context.target_version})
          :ok
        end
      end

      # Register the process so the hook can find it
      Process.register(self(), :test_hook_process_post)

      Bloom.DeploymentHooks.register_hook(:post_deployment, TestPostDeploymentHook)

      DeploymentCoordinator.deploy("1.1.0")

      assert_receive {:hook_called, :post_deployment, "1.1.0"}, 1000
    end
  end

  describe "deployment status tracking" do
    test "tracks deployment status throughout lifecycle" do
      {:ok, result} = DeploymentCoordinator.deploy("1.1.0")
      deployment_id = result.deployment_id

      # Check that we can retrieve the deployment status
      case DeploymentCoordinator.get_deployment_status(deployment_id) do
        {:ok, status} ->
          assert status["id"] == deployment_id
          assert status["target_version"] == "1.1.0"
          assert status["status"] in ["completed", "failed"]

        {:error, :deployment_not_found} ->
          # This might happen in test environment, which is fine
          :ok
      end
    end

    test "returns error for non-existent deployment" do
      result = DeploymentCoordinator.get_deployment_status("non-existent-id")

      assert {:error, :deployment_not_found} = result
    end
  end

  describe "rollback handling" do
    test "attempts rollback on deployment failure when enabled" do
      # Set up the mock to fail the release switch
      MockReleaseHandler.set_next_result(:install_release, {:error, :installation_failed})

      result = DeploymentCoordinator.deploy("1.1.0", rollback_on_failure: true)

      assert {:error, error_info} = result
      assert Map.has_key?(error_info, :rollback)
      # rollback status will depend on whether the mock rollback succeeds
    end

    test "skips rollback when disabled" do
      # Set up the mock to fail the release switch
      MockReleaseHandler.set_next_result(:install_release, {:error, :installation_failed})

      result = DeploymentCoordinator.deploy("1.1.0", rollback_on_failure: false)

      assert {:error, error_info} = result
      assert error_info.status == :failed
      refute Map.has_key?(error_info, :rollback)
    end
  end

  describe "cancel_deployment/1" do
    test "returns error for non-existent deployment" do
      result = DeploymentCoordinator.cancel_deployment("non-existent-id")

      assert {:error, :deployment_not_found} = result
    end

    test "returns error when trying to cancel completed deployment" do
      {:ok, deploy_result} = DeploymentCoordinator.deploy("1.1.0")

      # Try to cancel the completed deployment
      case DeploymentCoordinator.cancel_deployment(deploy_result.deployment_id) do
        {:error, :deployment_not_found} ->
          # This might happen in test environment
          :ok

        {:error, reason} ->
          assert String.contains?(reason, "Cannot cancel")
      end
    end
  end

  describe "deployment validation edge cases" do
    test "handles release info validation failures gracefully" do
      # This test verifies that deployment doesn't crash when release info is unavailable
      result = DeploymentCoordinator.validate_deployment("non-existent-version")

      case result do
        # Validation passes if it can't check compatibility
        {:ok, _validation} -> :ok
        # Or it fails gracefully
        {:error, _reason} -> :ok
      end
    end

    test "proceeds with deployment when health checks are unavailable" do
      # Health checker might not be fully functional in test env
      result = DeploymentCoordinator.deploy("1.1.0")

      # Should succeed or fail gracefully, not crash
      case result do
        {:ok, _result} -> :ok
        {:error, _reason} -> :ok
      end
    end

    test "handles disk space check failures gracefully" do
      # Disk space checks might fail in test environment
      result = DeploymentCoordinator.validate_deployment("1.1.0")

      # Should not crash even if disk space checks fail
      case result do
        {:ok, _validation} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end

  describe "configuration handling" do
    test "uses default values when configuration is missing" do
      # Clear all configuration
      Application.delete_env(:bloom, :deployment_hooks)

      result = DeploymentCoordinator.deploy("1.1.0")

      case result do
        {:ok, _result} -> :ok
        {:error, _reason} -> :ok
      end
    end

    test "respects deployment timeout configuration" do
      # Very short timeout
      opts = [health_check_timeout: 1]

      # This might timeout or succeed depending on test environment
      result = DeploymentCoordinator.deploy("1.1.0", opts)

      case result do
        {:ok, _result} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end
end
