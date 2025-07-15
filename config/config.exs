import Config

# Default Bloom configuration
config :bloom,
  # Disk checking commands - configure complete commands for each use case
  disk_usage_command: fn releases_dir -> {"df", ["-h", releases_dir], []} end,
  disk_space_command: fn path -> {"df", ["-m", path], [stderr_to_stdout: true]} end,
  current_disk_space_command: fn -> {"df", ["-m", "."], [stderr_to_stdout: true]} end,
  release_disk_usage_command: fn releases_dir -> {"du", ["-sh", releases_dir], []} end

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
