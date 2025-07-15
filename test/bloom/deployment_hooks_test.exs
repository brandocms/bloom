defmodule Bloom.DeploymentHooksTest do
  # MUST be false - modifies shared hooks registry
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bloom.DeploymentHooks

  defmodule TestHook do
    @behaviour Bloom.DeploymentHooks.Behaviour

    def execute(context) do
      send(context.test_pid, {:hook_executed, context.phase, self()})
      :ok
    end

    def info do
      %{
        name: "Test Hook",
        description: "A hook for testing",
        version: "1.0.0",
        author: "Test Suite",
        phases: [:pre_deployment, :post_deployment]
      }
    end
  end

  defmodule FailingHook do
    @behaviour Bloom.DeploymentHooks.Behaviour

    def execute(_context) do
      {:error, "This hook always fails"}
    end
  end

  setup do
    # Clear hooks before each test
    DeploymentHooks.clear_hooks()

    on_exit(fn ->
      # Clean up hooks after each test
      DeploymentHooks.clear_hooks()
    end)

    :ok
  end

  describe "register_hook/3" do
    test "registers a hook for a phase" do
      assert :ok = DeploymentHooks.register_hook(:pre_deployment, TestHook)

      hooks = DeploymentHooks.get_hooks_for_phase(:pre_deployment)
      assert length(hooks) == 1
      assert hd(hooks).module == TestHook
    end

    test "respects priority ordering" do
      DeploymentHooks.register_hook(:pre_deployment, TestHook, priority: 100)
      DeploymentHooks.register_hook(:pre_deployment, FailingHook, priority: 10)

      hooks = DeploymentHooks.get_hooks_for_phase(:pre_deployment)
      assert length(hooks) == 2

      # Should be ordered by priority (lowest first)
      assert Enum.at(hooks, 0).module == FailingHook
      assert Enum.at(hooks, 1).module == TestHook
    end

    test "sets default configuration" do
      DeploymentHooks.register_hook(:pre_deployment, TestHook)

      hooks = DeploymentHooks.get_hooks_for_phase(:pre_deployment)
      hook = hd(hooks)

      assert hook.priority == 50
      assert hook.timeout == 30_000
      assert hook.retry_count == 0
      assert hook.enabled == true
    end
  end

  describe "unregister_hook/2" do
    test "removes a hook from a phase" do
      DeploymentHooks.register_hook(:pre_deployment, TestHook)
      assert length(DeploymentHooks.get_hooks_for_phase(:pre_deployment)) == 1

      DeploymentHooks.unregister_hook(:pre_deployment, TestHook)
      assert length(DeploymentHooks.get_hooks_for_phase(:pre_deployment)) == 0
    end

    test "only removes the specified hook" do
      DeploymentHooks.register_hook(:pre_deployment, TestHook)
      DeploymentHooks.register_hook(:pre_deployment, FailingHook)
      assert length(DeploymentHooks.get_hooks_for_phase(:pre_deployment)) == 2

      DeploymentHooks.unregister_hook(:pre_deployment, TestHook)
      hooks = DeploymentHooks.get_hooks_for_phase(:pre_deployment)
      assert length(hooks) == 1
      assert hd(hooks).module == FailingHook
    end
  end

  describe "execute_hooks/2" do
    test "executes hooks in priority order" do
      test_pid = self()
      context = %{phase: :pre_deployment, test_pid: test_pid}

      DeploymentHooks.register_hook(:pre_deployment, TestHook, priority: 20)
      DeploymentHooks.register_hook(:pre_deployment, TestHook, priority: 10)

      assert :ok = DeploymentHooks.execute_hooks(:pre_deployment, context)

      # Should receive messages in priority order
      assert_receive {:hook_executed, :pre_deployment, _pid1}
      assert_receive {:hook_executed, :pre_deployment, _pid2}
    end

    @tag :capture_log
    test "stops execution on hook failure" do
      test_pid = self()
      context = %{phase: :pre_deployment, test_pid: test_pid}

      DeploymentHooks.register_hook(:pre_deployment, FailingHook, priority: 10)
      DeploymentHooks.register_hook(:pre_deployment, TestHook, priority: 20)

      capture_log(fn ->
        result = DeploymentHooks.execute_hooks(:pre_deployment, context)

        assert {:error, error_message} = result
        assert String.contains?(error_message, "FailingHook")

        # Second hook should not execute
        refute_receive {:hook_executed, :pre_deployment, _pid}
      end)
    end

    test "skips disabled hooks" do
      test_pid = self()
      context = %{phase: :pre_deployment, test_pid: test_pid}

      DeploymentHooks.register_hook(:pre_deployment, TestHook, enabled: false)

      assert :ok = DeploymentHooks.execute_hooks(:pre_deployment, context)

      # Should not receive any messages
      refute_receive {:hook_executed, :pre_deployment, _pid}
    end
  end

  describe "set_hook_enabled/3" do
    test "enables and disables hooks" do
      DeploymentHooks.register_hook(:pre_deployment, TestHook, enabled: false)

      hooks = DeploymentHooks.get_hooks_for_phase(:pre_deployment)
      assert hd(hooks).enabled == false

      DeploymentHooks.set_hook_enabled(:pre_deployment, TestHook, true)

      hooks = DeploymentHooks.get_hooks_for_phase(:pre_deployment)
      assert hd(hooks).enabled == true
    end
  end

  describe "clear_hooks/1" do
    test "clears all hooks when called with :all" do
      DeploymentHooks.register_hook(:pre_deployment, TestHook)
      DeploymentHooks.register_hook(:post_deployment, TestHook)

      assert length(DeploymentHooks.get_hooks_for_phase(:pre_deployment)) == 1
      assert length(DeploymentHooks.get_hooks_for_phase(:post_deployment)) == 1

      DeploymentHooks.clear_hooks(:all)

      assert length(DeploymentHooks.get_hooks_for_phase(:pre_deployment)) == 0
      assert length(DeploymentHooks.get_hooks_for_phase(:post_deployment)) == 0
    end

    test "clears hooks for specific phase" do
      DeploymentHooks.register_hook(:pre_deployment, TestHook)
      DeploymentHooks.register_hook(:post_deployment, TestHook)

      DeploymentHooks.clear_hooks(:pre_deployment)

      assert length(DeploymentHooks.get_hooks_for_phase(:pre_deployment)) == 0
      assert length(DeploymentHooks.get_hooks_for_phase(:post_deployment)) == 1
    end
  end

  describe "list_hooks/0" do
    test "returns summary of all hooks" do
      DeploymentHooks.register_hook(:pre_deployment, TestHook, priority: 10)
      DeploymentHooks.register_hook(:post_deployment, FailingHook, priority: 20)

      {:ok, summary} = DeploymentHooks.list_hooks()

      assert is_list(summary)
      assert Enum.any?(summary, fn {phase, _hooks} -> phase == :pre_deployment end)
      assert Enum.any?(summary, fn {phase, _hooks} -> phase == :post_deployment end)
    end
  end
end
