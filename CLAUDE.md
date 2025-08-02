# CLAUDE.md

This file provides guidance to Claude Code when working with the Bloom release management package.

## About Bloom

Bloom is a companion package to Florist that enables zero-downtime deployments using Erlang's `:release_handler`. While Florist handles the external deployment orchestration (building, uploading, etc.), Bloom runs inside the target application and manages the actual release switching.

## Relationship to Florist

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
- **Communication**: Florist uses SSH RPC via `bin/myapp rpc "expression"` to call Bloom functions

## Core Modules

### `Bloom.ReleaseManager`
Main API for release operations:
- `install_release/1` - Install release via `:release_handler.unpack_release/1`
- `switch_release/1` - Switch to installed release and make permanent
- `rollback_release/0` - Revert to previous release
- `list_releases/0` - List available releases
- `current_release/0` - Get current release info


### `Bloom.HealthChecker`
Health monitoring and validation:
- `run_checks/0` - Run all registered health checks (returns `true`/`false`)
- `post_switch_health_check/0` - Validate deployment after switch (returns `true`/`false`)
- `register_check/2` - Allow apps to register custom health checks
- Application-specific health validation

## Build Commands
- Build package: `mix compile`
- Run tests: `mix test`
- Format code: `mix format`
- Type checking: `mix dialyzer` (if added)
- Package for hex: `mix hex.build`

## Code Style Guidelines
- Follow standard Elixir conventions
- Use `@moduledoc` and `@doc` for all public functions
- Return proper Elixir terms for SSH RPC compatibility
- Health checker functions return `true`/`false` instead of `:ok`/`:error`
- Comprehensive error handling for `:release_handler` operations
- Minimal external dependencies to keep package lightweight

## Testing Guidelines
- Mock `:release_handler` calls in tests
- Test error scenarios and edge cases
- Integration tests with dummy releases
- Property-based testing for release validation

## Implementation Priority
1. **Core release management** (`Bloom.ReleaseManager`)
2. **Health checking** (`Bloom.HealthChecker`)
3. **Error handling and safety features**
4. **Advanced features** (retention, monitoring, etc.)

## Dependencies
Keep dependencies minimal for lightweight package:
- Standard library only for core functionality
- Optional dependencies for advanced features
- Avoid heavy frameworks or complex dependencies

## Target Applications Integration
Applications using Bloom need to:

1. Add dependency: `{:bloom, "~> 1.0"}`
2. Start in supervision tree: `Bloom.ReleaseManager`
3. Optional: Register custom health checks

## Development Notes
- `:release_handler` functions must be called from within the running node
- All operations should be wrapped with proper error handling
- Consider backwards compatibility when making changes
- Test with real OTP releases, not just unit tests