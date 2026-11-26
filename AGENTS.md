# Repository Guidelines

## Project Structure & Module Organization

`sb` is the CLI entry point and loads modules from `lib/`. State, rendering, services, certificates, status/logs, and tunnels have separate modules. Protocol renderers live in `protocols/`; installation uses `install.sh`/`setup.sh`; architecture notes are in `docs/`.

The source of truth is `/etc/sb-manager/state.json` plus protected secret and certificate files. Never edit generated `config.json` as persistent state.

## Development Policy

Do not add or restore test scripts, test environments, fixtures, test plans,
or test instructions. Do not provision disposable test hosts or containers.
Keep runtime configuration validation and atomic
candidate-check-install-rollback behavior as production features.

## Coding Style & Naming Conventions

Use Bash with `set -Eeuo pipefail`, two-space indentation, quoted expansions, and `local` variables. Prefer `snake_case` functions and variables; reserve `SBM_*` names for exported configuration paths and runtime settings. Keep protocol logic in `protocols/<name>.sh` and cross-protocol behavior in `lib/`. Use `jq --arg`/`--argjson` to construct JSON instead of string interpolation. Protect mutating operations with `with_lock` and preserve atomic candidate-check-install-rollback behavior.

## Commit & Pull Request Guidelines

Follow the existing Conventional Commit style: `feat:`, `fix:`, or `chore:` followed by an imperative summary. Keep commits scoped and reviewable. Pull requests should explain behavior changes, migration or rollback risk, supported distributions, and commands run. Include terminal output for CLI changes and update `README.md`, `CHANGELOG.md`, `VERSION`, or state documentation when relevant.

For every completed change, increment `VERSION`, synchronize the fallback and current-version documentation, update `CHANGELOG.md`, then commit and push to the GitHub repository. Keep Alpine/BusyBox and OpenRC compatibility alongside Debian/systemd.

## Security & Configuration Tips

Treat backups, exports, API tokens, node credentials, and private keys as secrets. Never commit generated configs or runtime data. Verify downloaded artifacts and retain least-privilege service settings. Ordinary installation and node operations must not automatically alter host firewalls. Explicit VPS initialization (`sb vps init` or installer `--init-vps`) installs Caddy/UFW/Fail2ban and opens 22/TCP, 80/TCP, 443/TCP and 443/UDP while preserving the current SSH port and existing rules.

## Panel Form Schema

`sb node schema` prints `schemas/node-form.json` (version 3); the web panel builds its "add node" form from it, laid out like 3x-ui's "add inbound" dialog. Whenever a `node add` flag, protocol, or allowed value changes, update that file in the same commit. Each field has a `group` (`basic`, `client`, `proto`, `transport`, `security`, `sniffing`, `advanced`), a `kind` (`text`, `number`, `select`, `radio`, `tags`, `switch`), and one of: a `flag`; a `set` list of `[target, path, fixed-value?]` entries that the panel writes into the inbound / outbound extension JSON; or a `post` command (`cmd` with `{id}`, `flag`, optional `suffix`) that runs after the node is created. A `set` field's `type` is `int` or `list`; kind `pairs` writes an object, kind `rows` an array of objects described by `columns` (`flat: true` with one column writes a plain list), kind `blocks` an array of `{type, settings}` chosen from `variants`. A field that other fields' `when` depends on must have a working `from` (or be a `set` field), or those fields are hidden — and so cleared — on every edit. `when_any` is a list of `when` groups of which one must hold. Top-level `patch_flags` names the flags that take `{set, unset}` patches of the extension (the panel then edits with those instead of sending the whole extension), `check.prefix` the options that turn `node add` into a validation-only run, and a protocol's `presets` (`label`, `note`, `values`) are starting points offered above the form. `when` shows a field only for the listed values of another field, `when_filled` only once another field has a value; `hidden_emit` is the flag value sent while the field is hidden. `value` prefills a field, `generate` (`uuid`, `hex:N`, `password:N`) and `random` (`[min, max]`) add a regenerate button and with `auto` start filled, `invert` sends a switch's flag when it is off, `readonly` rows only inform. For editing an existing node the top-level `edit.cmd` is the change command, a field's `from` is the path (or list of paths) of its current value in the node's JSON (`from_map` translates stored values, `edit_empty` is what clearing the field sends), `edit: "no"` marks a field that cannot be changed afterwards and `create_only` one that only exists at creation; each protocol's `state` is its name in the stored node. A protocol's `fields` entry may be an object (`{"key": …}` plus overrides). Never add a field that asks the operator to type JSON (`kind: json`): raw fragments are a CLI-only feature.

## Panel Feature Pages

`sb panel schema` prints `schemas/panel.json`: the pages, status lines, tables and actions the web panel shows besides the node form. Each action is a command template (`args` with `{field}`, `{row.key}` and optional `{field?}` placeholders) plus `fields` (the same kinds as the node form; a field with a `flag` is appended as an option). When a command, flag or JSON output changes, update this file in the same commit. A status item or column may carry a `map` (stored word → wording shown), a field `secret: true` (typed hidden, masked in the command shown), and a `source` (options read from a command's JSON, optionally with `filter`); `kind: tags` with a `source` lets the operator click several. Only offer commands that work without a terminal (no prompts) and never ask for JSON input.
