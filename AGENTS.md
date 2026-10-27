# Repository Guidelines

## Project Structure & Module Organization

`sb` is the CLI entry point and loads modules from `lib/`. State, rendering, services, certificates, backups, diagnostics, and tunnels have separate modules. Protocol renderers live in `protocols/`; installation uses `install.sh`/`setup.sh`; architecture notes are in `docs/`.

The source of truth is `/etc/sb-manager/state.json` plus protected secret and certificate files. Never edit generated `config.json` as persistent state.

## Development Policy

Do not add or restore test scripts, test environments, fixtures, test plans,
or test instructions. Do not provision disposable test hosts or containers.
Keep user-facing diagnostics, runtime configuration validation, and atomic
candidate-check-install-rollback behavior as production features.

## Coding Style & Naming Conventions

Use Bash with `set -Eeuo pipefail`, two-space indentation, quoted expansions, and `local` variables. Prefer `snake_case` functions and variables; reserve `SBM_*` names for exported configuration paths and runtime settings. Keep protocol logic in `protocols/<name>.sh` and cross-protocol behavior in `lib/`. Use `jq --arg`/`--argjson` to construct JSON instead of string interpolation. Protect mutating operations with `with_lock` and preserve atomic candidate-check-install-rollback behavior.

## Commit & Pull Request Guidelines

Follow the existing Conventional Commit style: `feat:`, `fix:`, or `chore:` followed by an imperative summary. Keep commits scoped and reviewable. Pull requests should explain behavior changes, migration or rollback risk, supported distributions, and commands run. Include terminal output for CLI changes and update `README.md`, `CHANGELOG.md`, `VERSION`, or state documentation when relevant.

For every completed change, increment `VERSION`, synchronize the fallback and current-version documentation, update `CHANGELOG.md`, then commit and push to the GitHub repository. Keep Alpine/BusyBox and OpenRC compatibility alongside Debian/systemd.

## Security & Configuration Tips

Treat backups, exports, API tokens, node credentials, and private keys as secrets. Never commit generated configs or runtime data. Verify downloaded artifacts, retain least-privilege service settings, and do not automatically alter host firewalls.
