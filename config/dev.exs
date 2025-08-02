import Config

# In development, use the mock release handler by default
# since we typically don't have real OTP releases
config :bloom,
  env: :dev,
  release_handler: Bloom.MockReleaseHandler,
  # Standard disk checking commands for development
  disk_usage_command: fn releases_dir -> {"df", ["-h", releases_dir], []} end,
  disk_space_command: fn path -> {"df", ["-m", path], [stderr_to_stdout: true]} end,
  current_disk_space_command: fn -> {"df", ["-m", "."], [stderr_to_stdout: true]} end,
  release_disk_usage_command: fn releases_dir -> {"du", ["-sh", releases_dir], []} end
