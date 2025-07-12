import Config

# Configure Bloom to use the mock release handler in tests
config :bloom,
  release_handler: Bloom.MockReleaseHandler,
  skip_file_checks: true