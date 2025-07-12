defmodule Bloom.ErrorInterpreterTest do
  use ExUnit.Case, async: true

  alias Bloom.ErrorInterpreter

  describe "interpret_error/2" do
    test "interprets already_installed error" do
      error = {:error, {:already_installed, "1.2.3"}}
      {message, suggestions, context} = ErrorInterpreter.interpret_error(error)

      assert message == "Release 1.2.3 is already installed"
      assert length(suggestions) > 0
      assert context.error_type == :already_installed
      assert context.version == "1.2.3"
    end

    test "interprets no_such_release error" do
      error = {:error, :no_such_release}
      context = %{version: "2.0.0"}
      {message, suggestions, _context} = ErrorInterpreter.interpret_error(error, context)

      assert message == "Release 2.0.0 not found"
      assert length(suggestions) > 0
      assert Enum.any?(suggestions, &String.contains?(&1, "unpack"))
    end

    test "interprets bad_relup_file error" do
      error = {:error, {:bad_relup_file, "missing file"}}
      {message, _suggestions, context} = ErrorInterpreter.interpret_error(error)

      assert String.contains?(message, "Invalid release upgrade file")
      assert context.error_type == :bad_relup_file
      assert context.reason == "missing file"
    end

    test "interprets health_check_failed error" do
      error = {:error, :health_check_failed}
      {message, suggestions, context} = ErrorInterpreter.interpret_error(error)

      assert message == "Post-switch health checks failed"
      assert context.error_type == :health_check_failed
      assert Enum.any?(suggestions, &String.contains?(&1, "health"))
    end

    test "interprets application_unhealthy error" do
      error = {:error, :application_unhealthy}
      {message, _suggestions, context} = ErrorInterpreter.interpret_error(error)

      assert String.contains?(message, "Application failed health checks")
      assert context.error_type == :application_unhealthy
    end

    test "interprets migration_failed error" do
      error = {:error, {:migration_failed, "connection timeout"}}
      {message, _suggestions, context} = ErrorInterpreter.interpret_error(error)

      assert String.contains?(message, "Database migration failed")
      assert context.error_type == :migration_failed
      assert context.reason == "connection timeout"
    end

    test "interprets string errors with version format" do
      error = {:error, "Invalid version format: v1.0.0. Expected format: X.Y.Z"}
      {message, suggestions, context} = ErrorInterpreter.interpret_error(error)

      assert message == "Invalid version format: v1.0.0. Expected format: X.Y.Z"
      assert context.error_type == :invalid_version_format
      assert Enum.any?(suggestions, &String.contains?(&1, "semantic versioning"))
    end

    test "interprets string errors with directory not found" do
      error = {:error, "Release directory not found for version 1.0.0"}
      {message, _suggestions, context} = ErrorInterpreter.interpret_error(error)

      assert String.contains?(message, "Release directory not found")
      assert context.error_type == :directory_not_found
    end

    test "interprets same version error" do
      error = {:error, "Cannot switch to the same version"}
      {message, _suggestions, context} = ErrorInterpreter.interpret_error(error)

      assert message == "Cannot switch to the same version"
      assert context.error_type == :same_version
    end

    test "handles unhandled error types" do
      error = {:error, :unknown_error_type}
      {message, _suggestions, context} = ErrorInterpreter.interpret_error(error)

      assert String.contains?(message, "Release operation failed")
      assert context.error_type == :unhandled
      assert context.original_error == {:error, :unknown_error_type}
    end

    test "adds context information" do
      error = {:error, :no_such_release}
      input_context = %{version: "1.0.0", operation: :install}
      {_message, _suggestions, context} = ErrorInterpreter.interpret_error(error, input_context)

      assert context.version == "1.0.0"
      assert context.operation == :install
      assert context.error_type == :no_such_release
      assert context.timestamp
      assert context.interpreter_version
    end
  end

  describe "format_error/2" do
    test "formats error as string with suggestions by default" do
      interpreted = {"Test error", ["Suggestion 1", "Suggestion 2"], %{}}
      result = ErrorInterpreter.format_error(interpreted)

      assert String.contains?(result, "Test error")
      assert String.contains?(result, "Suggested actions:")
      assert String.contains?(result, "1. Suggestion 1")
      assert String.contains?(result, "2. Suggestion 2")
    end

    test "formats error without suggestions when disabled" do
      interpreted = {"Test error", ["Suggestion 1"], %{}}
      result = ErrorInterpreter.format_error(interpreted, include_suggestions: false)

      assert result == "Test error"
      refute String.contains?(result, "Suggested actions")
    end

    test "formats error as map" do
      interpreted = {"Test error", ["Suggestion 1"], %{error_type: :test}}
      result = ErrorInterpreter.format_error(interpreted, format: :map)

      assert result.message == "Test error"
      assert result.suggestions == ["Suggestion 1"]
      assert result.context == %{}
    end

    test "includes context when requested" do
      context = %{error_type: :test, version: "1.0.0"}
      interpreted = {"Test error", [], context}

      result =
        ErrorInterpreter.format_error(interpreted,
          format: :map,
          include_context: true
        )

      assert result.context == context
    end
  end

  describe "get_error_details/1" do
    test "extracts context from interpreted error" do
      context = %{error_type: :test, version: "1.0.0"}
      interpreted = {"Test error", ["Suggestion"], context}
      details = ErrorInterpreter.get_error_details(interpreted)

      assert details == context
    end
  end
end
