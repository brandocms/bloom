# Bloom

Zero-downtime release management for Elixir applications using Erlang's `:release_handler`.

Bloom is a companion package to [Florist](https://github.com/your-org/florist) that enables safe, automated release switching with built-in health monitoring, validation, and automatic rollback capabilities.

## Features

- 🚀 **Zero-downtime deployments** using OTP hot code upgrades
- 🛡️ **Safety monitoring** with automatic rollback on failures
- 🔍 **Comprehensive validation** of releases before switching
- 💊 **Health checking** framework with customizable checks
- 🔐 **Secure RPC interface** for external deployment tools
- 📊 **Release metadata tracking** and deployment history
- ⚙️ **Highly configurable** with sensible defaults

## Architecture

```
┌─────────────┐    SSH/RPC     ┌─────────────────────┐
│   Florist   │ ──────────────▶ │   Target Server    │
│  (CLI Tool) │                │                    │
└─────────────┘                │ ┌─────────────────┐ │
                               │ │ Running App     │ │
                               │ │ (Phoenix/Brando)│ │
                               │ │                 │ │
                               │ │ ┌─────────────┐ │ │
                               │ │ │   Bloom     │ │ │
                               │ │ │  Package    │ │ │
                               │ │ └─────────────┘ │ │
                               │ └─────────────────┘ │
                               └─────────────────────┘
```

- **Florist**: External CLI tool that builds, uploads, and orchestrates deployments
- **Bloom**: Internal package that applications include to handle release switching
- **Communication**: Florist uses Erlang RPC to call Bloom functions on the running application

## Installation

Add `bloom` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bloom, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Add to your supervision tree

```elixir
# In your application.ex
def start(_type, _args) do
  children = [
    # Your existing children...
    Bloom.Application
  ]
  
  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### 2. Configure your application

```elixir
# config/config.exs
config :bloom,
  app_name: :my_app,
  releases_dir: "/opt/my_app/releases"
```

### 3. Use from Florist or manually

```elixir
# Install a release
Bloom.ReleaseManager.install_release("1.2.3")

# Switch to the release
Bloom.ReleaseManager.switch_release("1.2.3")

# Rollback if needed
Bloom.ReleaseManager.rollback_release()
```

## Core Modules

### Bloom.ReleaseManager

Main API for release operations:

```elixir
# Install release without switching
{:ok} = Bloom.ReleaseManager.install_release("1.2.3")

# Switch to installed release
{:ok} = Bloom.ReleaseManager.switch_release("1.2.3")

# List available releases
releases = Bloom.ReleaseManager.list_releases()

# Get current release info
{:ok, %{name: "my_app", version: "1.2.2"}} = Bloom.ReleaseManager.current_release()

# Rollback to previous release
{:ok} = Bloom.ReleaseManager.rollback_release()
```

### Bloom.HealthChecker

Health monitoring and validation:

```elixir
# Register custom health checks
Bloom.HealthChecker.register_check(:database, &MyApp.DatabaseChecker.check/0)
Bloom.HealthChecker.register_check(:cache, &MyApp.CacheChecker.check/0)

# Run all health checks
true = Bloom.HealthChecker.run_checks()

# Run post-switch validation
true = Bloom.HealthChecker.post_switch_health_check()
```

### Bloom.RPC

Secure interface for external tools:

```elixir
# These functions are called by Florist via :rpc.call/5
Bloom.RPC.install_release("1.2.3")
Bloom.RPC.switch_release("1.2.3")
Bloom.RPC.list_releases()
```

## Configuration

Bloom supports extensive configuration options:

```elixir
config :bloom,
  # Application settings
  app_name: :my_app,
  releases_dir: "/opt/my_app/releases",
  
  # Health monitoring
  memory_threshold_bytes: 1_073_741_824,  # 1GB
  min_processes: 10,
  max_process_ratio: 0.9,
  
  # RPC Authentication (optional)
  require_authentication: true,
  shared_secret: "your-secret-key",
  allowed_ips: ["127.0.0.1", "192.168.1.100"],
  
  # Release validation
  min_otp_version: "25.0",
  required_applications: [:kernel, :stdlib, :logger, :my_app],
  min_disk_space_mb: 500,
  
  # Safety monitoring
  max_error_rate_per_minute: 10,
  max_response_time_ms: 5000,
  
  # Database backup settings
  database_backup_enabled: true,
  database_backup_backend: Bloom.DatabaseBackup.Postgres,
  database_backup_retention_count: 5,
  database_backup_timeout_ms: 300_000,
  database_backup_directory: "/opt/backups",
  database_backup_required: true,
  require_backup_for_migrations: true,
  min_backup_space_mb: 1000,
  
  # Database migration settings
  database_migration_rollback_strategy: :ecto_first, # :ecto_first, :backup_only, :skip
  database_migration_timeout_ms: 180_000,
  
  # Callbacks
  rollback_failure_callback: &MyApp.Monitoring.alert_critical_failure/1,
  
  # Custom health checks
  health_checks: [
    database: &MyApp.DatabaseChecker.check/0,
    cache: &MyApp.CacheChecker.check/0,
    external_api: &MyApp.ExternalAPIChecker.check/0
  ]
```

### Configuration Options

#### Application Settings

- `app_name` - Name of your application (atom or string)
- `releases_dir` - Directory where releases are stored
- `app_root` - Root directory for metadata storage

#### Health Monitoring

- `memory_threshold_bytes` - Maximum memory usage before health check fails
- `min_processes` - Minimum number of processes that should be running
- `max_process_ratio` - Maximum ratio of process count to process limit

#### RPC Authentication

- `require_authentication` - Whether to require authentication for RPC calls
- `shared_secret` - Shared secret for authentication
- `allowed_ips` - List of allowed IP addresses for RPC calls

#### Release Validation

- `min_otp_version` - Minimum required OTP version
- `required_applications` - List of applications that must be running
- `min_disk_space_mb` - Minimum required disk space in MB
- `skip_file_checks` - Skip file system validation (useful for tests)

#### Safety Monitoring

- `max_error_rate_per_minute` - Maximum errors per minute before rollback
- `max_response_time_ms` - Maximum response time before considering unhealthy

#### Database Backup Settings

- `database_backup_enabled` - Enable automatic database backups before migrations
- `database_backup_backend` - Backend module for database backups
- `database_backup_retention_count` - Number of backups to keep
- `database_backup_timeout_ms` - Timeout for backup operations
- `database_backup_directory` - Directory to store backup files
- `database_backup_required` - Fail deployment if backup creation fails
- `require_backup_for_migrations` - Require backup when migrations are pending
- `min_backup_space_mb` - Minimum disk space required for backups

#### Database Migration Settings

- `database_migration_rollback_strategy` - Strategy for migration rollbacks
  - `:ecto_first` - Try Ecto rollback first, then backup restore
  - `:backup_only` - Only use backup restore, skip migration rollback
  - `:skip` - Skip all database rollback attempts
- `database_migration_timeout_ms` - Timeout for migration operations

#### Release Lifecycle Management

- `auto_cleanup_enabled` - Enable automatic cleanup of old releases (default: true)
- `release_retention_count` - Number of releases to keep (default: 5)
- `disk_space_warning_threshold` - Disk usage percentage to trigger warnings (default: 85)
- `releases_dir` - Directory where releases are stored (default: "releases")

#### Error Handling

- `detailed_error_logging` - Enable detailed error logging with context (default: true)
- `include_error_suggestions` - Include suggested actions in error messages (default: true)

#### Callbacks

- `rollback_failure_callback` - Function called when automatic rollback fails

## Custom Health Checks

You can register custom health checks that will be run during release validation:

```elixir
defmodule MyApp.DatabaseChecker do
  def check do
    case MyApp.Repo.query("SELECT 1") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:database_error, reason}}
    end
  end
end

# Register the check
Bloom.HealthChecker.register_check(:database, &MyApp.DatabaseChecker.check/0)
```

Health check functions should return:
- `:ok` or `true` for success
- `false` or `{:error, reason}` for failure

## Safety Features

### Automatic Rollback

Bloom includes comprehensive safety monitoring that can automatically rollback deployments:

- **Health check failures** during post-switch validation
- **High error rates** detected by safety monitoring
- **Memory threshold** exceeded
- **High process count** relative to system limits
- **Slow response times** indicating system stress

### Pre-switch Validation

Before switching to a new release, Bloom validates:

- **Release format** and version syntax
- **File integrity** of release archives
- **System resources** (memory, disk space, process count)
- **Application dependencies** and OTP version compatibility
- **Release compatibility** with current version

### Database Rollback Support

Bloom provides comprehensive database rollback capabilities:

#### Automatic Database Backups

When migrations are detected, Bloom automatically creates a database backup:

```elixir
# Backup is created automatically before migrations
Bloom.ReleaseManager.switch_release("1.2.3")  # Creates backup if migrations pending
```

#### Migration Rollback Strategies

Configure how database rollbacks are handled:

```elixir
config :bloom,
  database_migration_rollback_strategy: :ecto_first  # Default strategy
```

- **`:ecto_first`** - Attempts to rollback migrations using Ecto, falls back to backup restore
- **`:backup_only`** - Skips migration rollback, only restores from backup
- **`:skip`** - Disables database rollback entirely (not recommended)

#### Manual Database Operations

You can also manually manage database backups and migrations:

```elixir
# Check for pending migrations
pending = Bloom.MigrationTracker.check_pending_migrations()

# Create a backup manually
{:ok, backup_info} = Bloom.DatabaseBackup.create_backup("1.2.3")

# Run migrations manually
{:ok, executed} = Bloom.MigrationTracker.run_pending_migrations()

# Rollback migrations for a specific version
:ok = Bloom.MigrationTracker.rollback_deployment_migrations("1.2.3")

# Restore from backup
:ok = Bloom.DatabaseBackup.restore_backup("1.2.3")
```

### Deployment Metadata

Bloom tracks deployment history, migrations, and backups for rollback support:

```elixir
# Get deployment history
{:ok, deployments} = Bloom.Metadata.get_deployment_history()

# Get rollback target
{:ok, previous_version} = Bloom.Metadata.get_rollback_target()

# Get migration info for a deployment
{:ok, migration_info} = Bloom.Metadata.get_migration_info("1.2.3")

# Get backup info for a deployment
{:ok, backup_info} = Bloom.Metadata.get_backup_info("1.2.3")
```

## Testing

Bloom includes a comprehensive mock system for testing:

```elixir
# In test/test_helper.exs
Application.put_env(:bloom, :release_handler, Bloom.MockReleaseHandler)
Application.put_env(:bloom, :skip_file_checks, true)

# In your tests
setup do
  Bloom.MockReleaseHandler.clear_releases()
  Bloom.MockReleaseHandler.add_mock_release(:my_app, "1.0.0", :permanent)
  :ok
end

test "can install a release" do
  assert :ok = Bloom.ReleaseManager.install_release("1.1.0")
end
```

## Integration with Florist

Bloom is designed to work seamlessly with Florist:

```bash
# Florist commands that call Bloom via RPC
florist deploy 1.2.3
florist rollback
florist status
florist health-check
```

## Error Handling

Bloom provides detailed error messages for common failure scenarios:

```elixir
{:error, "Invalid version format: abc. Expected format: X.Y.Z or X.Y.Z-suffix"}
{:error, "Release not found - ensure release is properly installed"}
{:error, "Invalid release upgrade file - check release compatibility"}
{:error, "Insufficient disk space. Required: 500MB, Available: 200MB"}
{:error, "OTP version 24.0 is below minimum required 25.0"}
```

## Production Considerations

### Node Naming

Ensure your application runs with a proper node name for RPC communication:

```elixir
# In vm.args or releases config
-name myapp@hostname
# or
-sname myapp
```

### Security

- Use authentication for RPC calls in production
- Restrict allowed IP addresses
- Consider running behind a firewall
- Monitor access logs

### Monitoring

- Set up alerts for rollback failures
- Monitor deployment success rates
- Track health check failures
- Monitor system resources during deployments

### Resource Planning

- Ensure sufficient disk space for multiple releases
- Plan for memory overhead during upgrades
- Consider process limits and concurrent connections

## Contributing

1. Fork the repository
2. Create a feature branch
3. Write tests for your changes
4. Ensure all tests pass: `mix test`
5. Format code: `mix format`
6. Submit a pull request

## License

[Add your license here]

## Documentation

Full documentation is available on [HexDocs](https://hexdocs.pm/bloom).

## Support

- [GitHub Issues](https://github.com/your-org/bloom/issues)
- [Discussion Forum](https://github.com/your-org/bloom/discussions)