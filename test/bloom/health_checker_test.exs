defmodule Bloom.HealthCheckerTest do
  use ExUnit.Case, async: false

  alias Bloom.HealthChecker

  setup do
    # HealthChecker is already started by the application
    # Reset to clean state for each test
    reset_health_checker()

    on_exit(fn ->
      reset_health_checker()
    end)

    :ok
  end

  # Helper to reset HealthChecker to clean state
  defp reset_health_checker do
    # Get the current state and clear all registered checks except defaults
    # We can't restart the GenServer easily, so we'll reset its internal state
    GenServer.call(Bloom.HealthChecker, :reset_to_defaults)
  rescue
    # If the GenServer is not available, that's fine
    _ -> :ok
  end

  describe "register_check/2" do
    test "registers a custom health check" do
      check_fn = fn -> :ok end

      assert HealthChecker.register_check(:custom_check, check_fn) == :ok
    end

    test "requires function with arity 0" do
      assert_raise FunctionClauseError, fn ->
        HealthChecker.register_check(:bad_check, fn _arg -> :ok end)
      end
    end
  end

  describe "run_checks/0" do
    test "returns true when all checks pass" do
      # Register passing checks
      HealthChecker.register_check(:test_check1, fn -> :ok end)
      HealthChecker.register_check(:test_check2, fn -> true end)
      HealthChecker.register_check(:test_check3, fn -> {:ok, :data} end)

      # Should return true because all checks return valid success values
      assert HealthChecker.run_checks() == true
    end

    test "returns false when any check fails" do
      # Register mixed checks
      HealthChecker.register_check(:passing_check, fn -> :ok end)
      HealthChecker.register_check(:failing_check, fn -> false end)

      # Should return false because failing_check returns false
      assert HealthChecker.run_checks() == false
    end

    test "handles check exceptions gracefully" do
      # Register a check that raises an exception
      HealthChecker.register_check(:exception_check, fn ->
        raise "Test exception"
      end)

      # Should return false because exception_check raises an exception
      assert HealthChecker.run_checks() == false
    end

    test "handles invalid return values" do
      # Register a check with invalid return
      HealthChecker.register_check(:invalid_check, fn -> :invalid_return end)

      # Should return false because invalid_check returns invalid value
      assert HealthChecker.run_checks() == false
    end
  end

  describe "post_switch_health_check/0" do
    test "runs only critical checks" do
      # Register a non-critical check that would fail
      HealthChecker.register_check(:non_critical, fn -> false end)

      # Should still pass because non-critical checks are ignored in post-switch validation
      # Only :application, :memory, :processes checks are run
      assert HealthChecker.post_switch_health_check() == true
    end

    test "fails when critical checks fail" do
      # Register a critical check that fails
      # Since we can't easily mock erlang functions without meck,
      # we'll test the framework by registering a failing check
      HealthChecker.register_check(:application, fn -> {:error, :check_failed} end)

      # Should return false because the critical application check failed
      assert HealthChecker.post_switch_health_check() == false
    end
  end

  describe "default health checks" do
    test "application check passes with running applications" do
      # Should pass because we have applications running (at least :bloom and :ex_unit)
      assert HealthChecker.post_switch_health_check() == true
    end
  end
end
