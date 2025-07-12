defmodule Bloom.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Bloom.ReleaseManager,
      Bloom.HealthChecker,
      Bloom.RPC
    ]

    opts = [strategy: :one_for_one, name: Bloom.Supervisor]
    Supervisor.start_link(children, opts)
  end
end