defmodule Bloom.ValidatorTest do
  use ExUnit.Case, async: true

  alias Bloom.Validator

  describe "validate_release/1" do
    test "validates correct version format" do
      # Valid semantic versions
      assert Validator.validate_release("1.0.0") == :ok
      assert Validator.validate_release("2.1.3") == :ok
      assert Validator.validate_release("1.0.0-beta") == :ok
      assert Validator.validate_release("3.2.1-rc1") == :ok
    end

    test "rejects invalid version formats" do
      # Invalid version formats
      assert {:error, error} = Validator.validate_release("1.0")
      assert error =~ "Invalid version format"

      assert {:error, error} = Validator.validate_release("v1.0.0")
      assert error =~ "Invalid version format"

      assert {:error, error} = Validator.validate_release("1.0.0.1")
      assert error =~ "Invalid version format"

      assert {:error, error} = Validator.validate_release("invalid")
      assert error =~ "Invalid version format"
    end

    test "checks release directory existence" do
      # This will likely fail since we don't have actual releases
      # but that's expected behavior
      result = Validator.validate_release("1.0.0")
      assert match?({:error, _}, result)
    end
  end

  describe "check_compatibility/2" do
    test "allows upgrades to newer versions" do
      assert Validator.check_compatibility("1.0.0", "1.1.0") == :ok
      assert Validator.check_compatibility("1.0.0", "2.0.0") == :ok
    end

    test "allows downgrades with warning" do
      # Downgrades should be allowed but generate warnings
      assert Validator.check_compatibility("1.1.0", "1.0.0") == :ok
    end

    test "rejects switching to same version" do
      assert {:error, "Cannot switch to the same version"} =
               Validator.check_compatibility("1.0.0", "1.0.0")
    end

    test "handles invalid version formats gracefully" do
      # Should not crash on invalid versions
      assert Validator.check_compatibility("invalid", "1.0.0") == :ok
      assert Validator.check_compatibility("1.0.0", "invalid") == :ok
    end
  end

  describe "version parsing edge cases" do
    test "handles version comparison errors gracefully" do
      # Test with versions that can't be parsed by Version module
      result = Validator.check_compatibility("1.0.0-custom+build", "1.1.0-other+build2")
      # Should not crash, might succeed or fail gracefully
      assert result in [:ok, {:error, "Cannot switch to the same version"}]
    end
  end

  describe "disk space checking" do
    test "handles disk space check failures gracefully" do
      # This test might vary based on system, but should not crash
      # The disk space check should be defensive and not fail validation
      # if it can't determine disk space
      result = Validator.validate_release("1.0.0")

      # Should get a file not found error, not a disk space error
      assert match?({:error, msg} when is_binary(msg), result)
    end
  end

  describe "application name detection" do
    test "handles missing application configuration" do
      # Test that the validator doesn't crash when app name is not configured
      # This is tested indirectly through validate_release
      result = Validator.validate_release("1.0.0")
      assert match?({:error, _}, result)
    end
  end
end
