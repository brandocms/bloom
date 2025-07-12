defmodule Bloom.ReleaseHandler do
  @moduledoc """
  Adapter module for release handler operations.
  
  This module provides a unified interface to either the real
  :release_handler or a mock implementation based on configuration.
  """

  @doc """
  Get the configured release handler module.
  
  Returns :release_handler in production, or a mock module in test/dev.
  """
  def handler do
    Application.get_env(:bloom, :release_handler, :release_handler)
  end

  @doc """
  Delegates to the configured handler's unpack_release/1
  """
  def unpack_release(version) do
    handler().unpack_release(version)
  end

  @doc """
  Delegates to the configured handler's install_release/1
  """
  def install_release(version) do
    handler().install_release(version)
  end

  @doc """
  Delegates to the configured handler's make_permanent/1
  """
  def make_permanent(version) do
    handler().make_permanent(version)
  end

  @doc """
  Delegates to the configured handler's which_releases/0
  """
  def which_releases do
    handler().which_releases()
  end

  @doc """
  Delegates to the configured handler's which_releases/1
  """
  def which_releases(type) do
    handler().which_releases(type)
  end
end