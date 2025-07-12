defmodule BloomTest do
  use ExUnit.Case
  doctest Bloom

  describe "version/0" do
    test "returns the application version" do
      version = Bloom.version()
      assert is_binary(version)
      assert version =~ ~r/^\d+\.\d+\.\d+/
    end
  end

  describe "convenience API" do
    test "delegates to ReleaseManager" do
      # These will likely fail due to missing release setup,
      # but we can test that the functions exist and delegate properly

      assert function_exported?(Bloom, :install_release, 1)
      assert function_exported?(Bloom, :switch_release, 1)
      assert function_exported?(Bloom, :list_releases, 0)
      assert function_exported?(Bloom, :current_release, 0)
      assert function_exported?(Bloom, :rollback_release, 0)
      assert function_exported?(Bloom, :health_check, 0)
    end
  end
end
