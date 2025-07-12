defmodule Bloom.HealthCheckerTest do
  use ExUnit.Case, async: false

  alias Bloom.HealthChecker

  setup do
    # HealthChecker is already started by the application
    # Just ensure it's available for testing
    :ok
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

      assert HealthChecker.run_checks() == true
    end

    test "returns false when any check fails" do
      # Register mixed checks
      HealthChecker.register_check(:passing_check, fn -> :ok end)
      HealthChecker.register_check(:failing_check, fn -> false end)

      assert HealthChecker.run_checks() == false
    end

    test "handles check exceptions gracefully" do
      # Register a check that raises an exception
      HealthChecker.register_check(:exception_check, fn ->
        raise "Test exception"
      end)

      assert HealthChecker.run_checks() == false
    end

    test "handles invalid return values" do
      # Register a check with invalid return
      HealthChecker.register_check(:invalid_check, fn -> :invalid_return end)

      assert HealthChecker.run_checks() == false
    end
  end

  describe "post_switch_health_check/0" do
    test "runs only critical checks" do
      # Register a non-critical check
      HealthChecker.register_check(:non_critical, fn -> false end)

      # Should still pass because non-critical checks are not run
      assert HealthChecker.post_switch_health_check() == true
    end

    test "fails when critical checks fail" do
      # Register a critical check that fails
      # Since we can't easily mock erlang functions without meck,
      # we'll test the framework by registering a failing check
      HealthChecker.register_check(:application, fn -> false end)

      assert HealthChecker.post_switch_health_check() == false
    end
  end

  describe "default health checks" do
    test "application check passes with running applications" do
      # This should pass as we have applications running in the test environment
      assert HealthChecker.post_switch_health_check() == true
    end
  end
end
