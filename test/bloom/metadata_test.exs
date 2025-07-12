defmodule Bloom.MetadataTest do
  use ExUnit.Case, async: false

  alias Bloom.Metadata

  @test_metadata_dir "test/tmp"

  setup do
    # Clean up any existing test metadata
    File.rm_rf(@test_metadata_dir)
    File.mkdir_p!(@test_metadata_dir)

    # Set test configuration
    Application.put_env(:bloom, :app_root, @test_metadata_dir)

    on_exit(fn ->
      File.rm_rf(@test_metadata_dir)
      Application.delete_env(:bloom, :app_root)
    end)

    :ok
  end

  describe "init_metadata_storage/0" do
    test "creates metadata file if it doesn't exist" do
      assert Metadata.init_metadata_storage() == :ok

      metadata_file = Path.join([@test_metadata_dir, "priv", "release_metadata.json"])
      assert File.exists?(metadata_file)

      # Check initial content
      {:ok, content} = File.read(metadata_file)
      {:ok, data} = Jason.decode(content)

      assert data["version"] == "1.0"
      assert data["deployments"] == []
      assert Map.has_key?(data, "created_at")
    end

    test "does not overwrite existing metadata file" do
      # Initialize once
      assert Metadata.init_metadata_storage() == :ok

      # Save some data
      assert Metadata.save_release_info("1.0.0") == :ok

      # Initialize again
      assert Metadata.init_metadata_storage() == :ok

      # Data should still be there
      assert {:ok, [deployment]} = Metadata.get_deployment_history(1)
      assert deployment["version"] == "1.0.0"
    end
  end

  describe "save_release_info/2" do
    setup do
      Metadata.init_metadata_storage()
      :ok
    end

    test "saves deployment information" do
      info = %{deployer: "test", environment: "staging"}

      assert Metadata.save_release_info("1.2.3", info) == :ok

      assert {:ok, [deployment]} = Metadata.get_deployment_history(1)
      assert deployment["version"] == "1.2.3"
      assert deployment["info"]["deployer"] == "test"
      assert deployment["info"]["environment"] == "staging"
      assert Map.has_key?(deployment, "deployed_at")
      assert Map.has_key?(deployment, "deployed_by")
    end

    test "maintains deployment history order" do
      # Deploy multiple versions
      Metadata.save_release_info("1.0.0")
      Metadata.save_release_info("1.1.0")
      Metadata.save_release_info("1.2.0")

      {:ok, history} = Metadata.get_deployment_history()

      # Should be in reverse chronological order (newest first)
      versions = Enum.map(history, & &1["version"])
      assert versions == ["1.2.0", "1.1.0", "1.0.0"]
    end
  end

  describe "get_rollback_target/0" do
    setup do
      Metadata.init_metadata_storage()
      :ok
    end

    test "returns previous deployment as rollback target" do
      Metadata.save_release_info("1.0.0")
      Metadata.save_release_info("1.1.0")

      assert {:ok, "1.0.0"} = Metadata.get_rollback_target()
    end

    test "returns error when no rollback target available" do
      # Clear the mock releases so there's no current release
      Bloom.MockReleaseHandler.clear_releases()

      # Initialize metadata storage first
      Metadata.init_metadata_storage()

      # Only one deployment with no previous version
      Metadata.save_release_info("1.0.0")

      # Should fall back to checking deployments, but find no previous
      assert {:error, :no_rollback_target} = Metadata.get_rollback_target()
    end

    test "returns error when no deployments exist" do
      assert {:error, :no_rollback_target} = Metadata.get_rollback_target()
    end
  end

  describe "get_deployment_history/1" do
    setup do
      Metadata.init_metadata_storage()
      :ok
    end

    test "returns limited deployment history" do
      # Create more deployments than the limit
      for i <- 1..10 do
        Metadata.save_release_info("1.#{i}.0")
      end

      {:ok, history} = Metadata.get_deployment_history(3)
      assert length(history) == 3

      # Should be newest first
      versions = Enum.map(history, & &1["version"])
      assert versions == ["1.10.0", "1.9.0", "1.8.0"]
    end

    test "returns empty list when no deployments" do
      assert {:ok, []} = Metadata.get_deployment_history()
    end
  end

  describe "get_release_info/1" do
    setup do
      Metadata.init_metadata_storage()
      :ok
    end

    test "returns info for specific release version" do
      info = %{build_number: 123}
      Metadata.save_release_info("1.2.3", info)

      assert {:ok, deployment} = Metadata.get_release_info("1.2.3")
      assert deployment["version"] == "1.2.3"
      assert deployment["info"]["build_number"] == 123
    end

    test "returns error for non-existent version" do
      assert {:error, :version_not_found} = Metadata.get_release_info("9.9.9")
    end
  end

  describe "cleanup_old_records/1" do
    setup do
      Metadata.init_metadata_storage()
      :ok
    end

    test "removes old deployment records" do
      # Create more records than we want to keep
      for i <- 1..10 do
        Metadata.save_release_info("1.#{i}.0")
      end

      # Keep only 3 most recent
      assert Metadata.cleanup_old_records(3) == :ok

      {:ok, history} = Metadata.get_deployment_history()
      assert length(history) == 3

      # Should keep newest records
      versions = Enum.map(history, & &1["version"])
      assert versions == ["1.10.0", "1.9.0", "1.8.0"]
    end

    test "does nothing when record count is within limit" do
      Metadata.save_release_info("1.0.0")
      Metadata.save_release_info("1.1.0")

      assert Metadata.cleanup_old_records(5) == :ok

      {:ok, history} = Metadata.get_deployment_history()
      assert length(history) == 2
    end
  end
end
