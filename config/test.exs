import Config

# Configure Bloom to use the mock release handler in tests
config :bloom,
  release_handler: Bloom.MockReleaseHandler,
  skip_file_checks: true,
  # Suppress stderr in test environment to avoid noise
  disk_usage_command: fn _releases_dir -> {"sh", ["-c", "df -h releases 2>/dev/null || true"], []} end,
  disk_space_command: fn _path -> {"sh", ["-c", "df -m . 2>/dev/null || true"], []} end,
  current_disk_space_command: fn -> {"sh", ["-c", "df -m . 2>/dev/null || true"], []} end,
  release_disk_usage_command: fn _releases_dir -> {"sh", ["-c", "du -sh releases 2>/dev/null || true"], []} end

# Allow info level for capture_log but suppress console output during tests
config :logger,
  level: :info

# Suppress console output but allow capture_log to work
config :logger, :console,
  level: :error,
  format: "[$level] $message\n"
