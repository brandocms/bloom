defmodule Bloom.MockReleaseHandler do
  @moduledoc """
  Mock implementation of :release_handler for testing purposes.

  This module simulates the behavior of Erlang's :release_handler
  when running in development or test environments where actual
  OTP releases are not available.
  """

  use GenServer
  require Logger

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Mock unpack_release/1 - simulates unpacking a release
  """
  def unpack_release(version) do
    GenServer.call(__MODULE__, {:unpack_release, version})
  end

  @doc """
  Mock install_release/1 - simulates installing a release
  """
  def install_release(version) do
    GenServer.call(__MODULE__, {:install_release, version})
  end

  @doc """
  Mock make_permanent/1 - simulates making a release permanent
  """
  def make_permanent(version) do
    GenServer.call(__MODULE__, {:make_permanent, version})
  end

  @doc """
  Mock which_releases/0 - returns list of mock releases
  """
  def which_releases do
    GenServer.call(__MODULE__, :which_releases)
  end

  @doc """
  Mock which_releases/1 - returns current release info
  """
  def which_releases(:current) do
    GenServer.call(__MODULE__, {:which_releases, :current})
  end

  @doc """
  Mock remove_release/1 - simulates removing a release
  """
  def remove_release(version) do
    GenServer.call(__MODULE__, {:remove_release, version})
  end

  # Test helpers

  @doc """
  Set up a mock release for testing
  """
  def add_mock_release(name, version, status \\ :old) do
    GenServer.call(__MODULE__, {:add_release, name, version, status})
  end

  @doc """
  Clear all mock releases
  """
  def clear_releases do
    GenServer.call(__MODULE__, :clear_releases)
  end

  @doc """
  Set the behavior for the next operation (success or specific error)
  """
  def set_next_result(operation, result) do
    GenServer.call(__MODULE__, {:set_next_result, operation, result})
  end

  @doc """
  Reset to initial state for test isolation
  """
  def reset_to_initial_state do
    GenServer.call(__MODULE__, :reset_to_initial_state)
  end

  # Server implementation

  @impl true
  def init(_opts) do
    state = %{
      releases: [
        {:bloom_test, ~c"0.1.0", [:kernel, :stdlib], :permanent}
      ],
      current_version: ~c"0.1.0",
      next_results: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:unpack_release, version}, _from, state) do
    Logger.debug("MockReleaseHandler: unpack_release(#{version})")

    result =
      case get_next_result(state, :unpack_release) do
        nil ->
          # Default behavior - check if version format is valid
          if valid_version?(version) do
            {:ok, {:unpacked, version}}
          else
            {:error, :bad_release_name}
          end

        result ->
          result
      end

    new_state = clear_next_result(state, :unpack_release)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:install_release, version}, _from, state) do
    Logger.debug("MockReleaseHandler: install_release(#{version})")

    result =
      case get_next_result(state, :install_release) do
        nil ->
          # Default behavior - always allow installation for switch operations
          {:ok, {:installed, version}}

        result ->
          result
      end

    new_state = clear_next_result(state, :install_release)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:make_permanent, version}, _from, state) do
    Logger.debug("MockReleaseHandler: make_permanent(#{version})")

    result =
      case get_next_result(state, :make_permanent) do
        nil -> :ok
        result -> result
      end

    new_state =
      state
      |> update_release_status(version, :permanent)
      |> clear_next_result(:make_permanent)

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:which_releases, _from, state) do
    Logger.debug("MockReleaseHandler: which_releases()")
    {:reply, state.releases, state}
  end

  @impl true
  def handle_call({:which_releases, :current}, _from, state) do
    Logger.debug("MockReleaseHandler: which_releases(:current)")

    current =
      Enum.find(state.releases, fn {_name, _version, _libs, status} ->
        status == :permanent
      end)

    result = if current, do: [current], else: []
    {:reply, result, state}
  end

  @impl true
  def handle_call({:remove_release, version}, _from, state) do
    Logger.debug("MockReleaseHandler: remove_release(#{version})")

    result =
      case get_next_result(state, :remove_release) do
        nil ->
          # Default behavior - check if release exists and can be removed
          release_exists =
            Enum.any?(state.releases, fn {_name, v, _libs, _status} ->
              to_string(v) == version
            end)

          cond do
            not release_exists ->
              {:error, :no_such_release}

            # Don't allow removing the current release (permanent status)
            release_is_permanent?(state, version) ->
              {:error, {:permanent_release, version}}

            true ->
              :ok
          end

        result ->
          result
      end

    new_state =
      case result do
        :ok ->
          # Remove the release from the list
          new_releases =
            Enum.reject(state.releases, fn {_name, v, _libs, _status} ->
              to_string(v) == version
            end)

          state
          |> Map.put(:releases, new_releases)
          |> clear_next_result(:remove_release)

        _ ->
          clear_next_result(state, :remove_release)
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:add_release, name, version, status}, _from, state) do
    release = {name, to_charlist(version), [:kernel, :stdlib], status}
    new_releases = [release | state.releases]
    new_state = %{state | releases: new_releases}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:clear_releases, _from, state) do
    new_state = %{state | releases: []}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_next_result, operation, result}, _from, state) do
    new_results = Map.put(state.next_results, operation, result)
    new_state = %{state | next_results: new_results}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:reset_to_initial_state, _from, _state) do
    # Reset to exactly the same state as init/1
    initial_state = %{
      releases: [
        {:bloom_test, ~c"0.1.0", [:kernel, :stdlib], :permanent}
      ],
      current_version: ~c"0.1.0",
      next_results: %{}
    }

    {:reply, :ok, initial_state}
  end

  # Private helpers

  defp valid_version?(version) do
    String.match?(version, ~r/^\d+\.\d+\.\d+(-\w+)?$/)
  end

  defp update_release_status(state, version, new_status) do
    version_charlist = to_charlist(version)

    new_releases =
      Enum.map(state.releases, fn {name, v, libs, _status} = release ->
        if v == version_charlist do
          {name, v, libs, new_status}
        else
          # Make other releases :old if this one is becoming permanent
          if new_status == :permanent do
            {name, v, libs, :old}
          else
            release
          end
        end
      end)

    %{state | releases: new_releases}
  end

  defp release_is_permanent?(state, version) do
    version_charlist = to_charlist(version)

    Enum.any?(state.releases, fn {_name, v, _libs, status} ->
      v == version_charlist and status == :permanent
    end)
  end

  defp get_next_result(state, operation) do
    Map.get(state.next_results, operation)
  end

  defp clear_next_result(state, operation) do
    new_results = Map.delete(state.next_results, operation)
    %{state | next_results: new_results}
  end
end
