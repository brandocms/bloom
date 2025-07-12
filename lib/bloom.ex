defmodule Bloom do
  @moduledoc """
  Zero-downtime release management for Elixir applications.

  Bloom enables safe release switching using Erlang's `:release_handler`
  with built-in health checks, validation, and automatic rollback capabilities.

  ## Overview

  Bloom is designed to work alongside Florist, a deployment orchestration tool.
  While Florist handles building, uploading, and managing deployments externally,
  Bloom runs inside your application and manages the actual release switching
  using OTP's proven release management capabilities.

  ## Quick Start

  1. Add Bloom to your application dependencies:

      ```elixir
      # mix.exs
      def deps do
        [
          {:bloom, "~> 0.1.0"}
        ]
      end
      ```

  2. Start Bloom in your supervision tree:

      ```elixir
      # application.ex
      def start(_type, _args) do
        children = [
          # your existing children...
          Bloom.ReleaseManager
        ]
        
        Supervisor.start_link(children, opts)
      end
      ```

  3. Ensure your release has proper OTP structure and node naming

  ## Main Modules

  - `Bloom.ReleaseManager` - Core release operations
  - `Bloom.HealthChecker` - Health monitoring and validation  
  - `Bloom.RPC` - Remote procedure call interface

  ## Usage

  Once integrated, Bloom can be controlled via Florist CLI commands:

      florist prod release:install v1.2.3
      florist prod release:switch v1.2.3
      florist prod release:list
      florist prod release:rollback

  Or programmatically:

      Bloom.ReleaseManager.install_release("1.2.3")
      Bloom.ReleaseManager.switch_release("1.2.3")
      Bloom.ReleaseManager.list_releases()

  ## Health Checks

  Register custom health checks for your application:

      Bloom.HealthChecker.register_check(:database, &MyApp.Database.health_check/0)
      Bloom.HealthChecker.register_check(:cache, &MyApp.Cache.ping/0)

  ## Safety Features

  - Pre-switch validation
  - Post-switch health verification
  - Automatic rollback on failure
  - Release compatibility checking
  - Comprehensive error handling

  Bloom helps your applications bloom into new releases safely and reliably.
  """

  @doc """
  Get the current version of Bloom.
  """
  def version do
    Application.spec(:bloom, :vsn) |> to_string()
  end

  # Convenience API - delegates to ReleaseManager

  @doc """
  Install a release. See `Bloom.ReleaseManager.install_release/1`.
  """
  def install_release(version), do: Bloom.ReleaseManager.install_release(version)

  @doc """
  Switch to a release. See `Bloom.ReleaseManager.switch_release/1`.
  """
  def switch_release(version), do: Bloom.ReleaseManager.switch_release(version)

  @doc """
  List available releases. See `Bloom.ReleaseManager.list_releases/0`.
  """
  def list_releases, do: Bloom.ReleaseManager.list_releases()

  @doc """
  Get current release info. See `Bloom.ReleaseManager.current_release/0`.
  """
  def current_release, do: Bloom.ReleaseManager.current_release()

  @doc """
  Rollback to previous release. See `Bloom.ReleaseManager.rollback_release/0`.
  """
  def rollback_release, do: Bloom.ReleaseManager.rollback_release()

  @doc """
  Run health checks. See `Bloom.HealthChecker.run_checks/0`.
  """
  def health_check, do: Bloom.HealthChecker.run_checks()

  # Lifecycle management API

  @doc """
  Clean up old releases. See `Bloom.LifecycleManager.cleanup_old_releases/1`.
  """
  def cleanup_old_releases(opts \\ []), do: Bloom.LifecycleManager.cleanup_old_releases(opts)

  @doc """
  Remove a specific release. See `Bloom.LifecycleManager.remove_release/2`.
  """
  def remove_release(version, opts \\ []),
    do: Bloom.LifecycleManager.remove_release(version, opts)

  @doc """
  Check disk space usage. See `Bloom.LifecycleManager.check_disk_space/1`.
  """
  def check_disk_space(opts \\ []), do: Bloom.LifecycleManager.check_disk_space(opts)

  @doc """
  Get detailed release information. See `Bloom.LifecycleManager.get_release_info/0`.
  """
  def get_release_info, do: Bloom.LifecycleManager.get_release_info()
end
