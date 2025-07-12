defmodule Bloom.MixProject do
  use Mix.Project

  def project do
    [
      app: :bloom,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Bloom",
      source_url: "https://github.com/your-org/bloom"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Bloom.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.0"},
      {:ecto, "~> 3.0"},
      {:ecto_sql, "~> 3.0"}
    ]
  end

  defp description do
    """
    Zero-downtime release management for Elixir applications using Erlang's :release_handler.
    Bloom enables safe release switching with automatic rollback capabilities.
    """
  end

  defp package do
    [
      files: ~w(lib .formatter.exs mix.exs README* CHANGELOG*),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/your-org/bloom",
        "Florist" => "https://github.com/your-org/florist"
      }
    ]
  end
end
