import Config

# In development, use the mock release handler by default
# since we typically don't have real OTP releases
config :bloom,
  release_handler: Bloom.MockReleaseHandler
