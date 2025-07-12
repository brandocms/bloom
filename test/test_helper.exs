# Configure test environment
Application.put_env(:bloom, :release_handler, Bloom.MockReleaseHandler)
Application.put_env(:bloom, :skip_file_checks, true)

ExUnit.start()
