defmodule Bloom.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Initialize metadata storage
    Bloom.Metadata.init_metadata_storage()

    # Base children that are always started
    base_children = [
      Bloom.ReleaseManager,
      Bloom.HealthChecker,
      Bloom.SafetyMonitor
    ]

    # Add MockReleaseHandler in test environment
    children =
      if Application.get_env(:bloom, :env, :prod) == :test do
        [Bloom.MockReleaseHandler | base_children]
      else
        base_children
      end

    opts = [strategy: :one_for_one, name: Bloom.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
