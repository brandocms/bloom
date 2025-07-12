import Config

# In production, use the real :release_handler
# (this is the default, but being explicit)
config :bloom,
  release_handler: :release_handler