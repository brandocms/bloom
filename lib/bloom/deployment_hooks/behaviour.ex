defmodule Bloom.DeploymentHooks.Behaviour do
  @moduledoc """
  Behaviour definition for deployment hooks.

  Modules implementing this behaviour can be registered as deployment hooks
  to run custom logic during different phases of the deployment process.
  """

  @doc """
  Execute the hook with the given deployment context.

  The context contains information about the deployment including:
  - `id` - Unique deployment identifier
  - `target_version` - Version being deployed
  - `started_at` - Deployment start timestamp
  - `options` - Deployment options
  - `phase` - Current deployment phase

  Should return:
  - `:ok` - Hook executed successfully
  - `{:ok, result}` - Hook executed successfully with result
  - `{:error, reason}` - Hook failed with reason
  """
  @callback execute(context :: map()) :: :ok | {:ok, any()} | {:error, any()}

  @doc """
  Optional callback to provide hook metadata and configuration.

  Should return a map with hook information:
  - `name` - Human readable name
  - `description` - What the hook does
  - `version` - Hook version
  - `author` - Hook author
  - `phases` - List of phases this hook can be used in
  """
  @callback info() :: map()

  @optional_callbacks info: 0
end
