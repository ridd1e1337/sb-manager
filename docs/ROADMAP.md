# sb-manager Improvement Roadmap

## Goal and Standards Baseline

The project will evolve from an alpha protocol installer into a dependable, state-driven sing-box server manager. The configuration baseline is sing-box `1.14.0`; 1.13-compatible configurations remain supported where the core permits. Configuration fields must follow the official sing-box documentation and JSON Schema, and every rendered configuration must pass the target core's `sing-box check`.

Opaque generated patches are not accepted as source changes. Work must be reviewable as normal commits, preserve least-privilege services, and keep `state.json` plus protected credentials as the source of truth.

## Phase 1 — State Safety and Recovery

- [x] Add strict state shape and semantic validation with a versioned schema.
- [x] Add explicit, one-way state migration infrastructure.
- [x] Hold the manager lock across every read-modify-write operation.
- [x] Make state, generated config, credentials, and certificates one recoverable transaction.
- [x] Harden backup restore against traversal, links, special files, and archive bombs.
- [x] Add encrypted backup support.

## Phase 2 — Trusted Installation and Upgrades

- [x] Publish immutable releases with checksums and a signed provenance path.
- [x] Pin bootstrap installations to a tag or commit instead of mutable `main`.
- [x] Require verified sing-box, cloudflared, and acme.sh artifacts.
- [x] Keep the default install disk-friendly: Cloudflared and feature-heavy
  dependencies are opt-in/lazy, with bounded core and upgrade-backup retention.
- [x] Record installed versions, URLs, digests, and build tags.
- [x] Treat minor/major core upgrades as compatibility migrations and retain an explicit known-good core/config pair.
- [x] Validate certificate SAN, chain, permissions, reload, and rollback after renewal.

## Phase 3 — Operations and Diagnostics

- [x] Add `sb probe NODE_ID` and `sb doctor --network` for DNS, listeners, TLS, UDP/QUIC, IPv4/IPv6 exposure, and firewall guidance.
- [x] Add log retention, disk usage checks, resource limits, and secret-safe diagnostics.

## Phase 4 — Protocol and User Model

- [x] Separate listeners/nodes from users so credentials can be added, disabled, rotated, and revoked independently.
- [x] Add VLESS Reality, Trojan TLS, and TUIC first; include Naive and the ShadowTLS outer transport, with their security boundaries documented.
- [x] Detect public addresses with explicit source tracking and preserve manual overrides.
- [x] Gate every field by core version and required build tag.

## Phase 5 — Export and Protected Control Plane

- [x] Export complete sing-box client profiles, subscriptions, DNS/routing templates, and optional compatible formats.
- [x] Add expiring subscription tokens without exposing root-managed state.
- [x] Evaluate the sing-box 1.14 API/Dashboard only on loopback or a protected tunnel with strong authentication and audit logging.

## Optional Nginx Stream Port Multiplexing

- [x] Add exact-SNI TCP passthrough without TLS termination.
- [x] Keep routed sing-box backends on unique loopback ports.
- [x] Preserve direct ports and restore them when multiplexing is disabled.
- [x] Integrate CLI, panel, systemd sandbox, diagnostics, exports, backup normalization, uninstall, and transaction rollback.
- [x] Reject unsupported protocols, duplicate/mismatched SNI, duplicate backends, unknown SNI, and occupied frontend ports.

## Node Traffic Accounting and Control

- [x] Keep traffic policy in node state and accumulated counters in a protected runtime journal.
- [x] Count TCP/UDP and IPv4/IPv6 upload/download traffic on effective direct, Tunnel, and Nginx Stream listeners.
- [x] Enforce total/download monthly quotas and independent directional rate ceilings in an owned nftables table.
- [x] Preserve counters across rule changes, backup/restore, clean shutdown, systemd reboot, and OpenRC startup.
- [x] Avoid taking over existing host qdiscs or implicitly opening firewall ports.

## Explicit Firewall Protection

- [x] Add panel/CLI setup for Fail2ban SSH protection with a 180-second window, five retries, and permanent bans.
- [x] Add panel/CLI UFW installation, idempotent TCP 22/80/443 allows, and active protocol-port allows before enablement.
- [x] Snapshot existing iptables/UFW status and Fail2ban jail configuration before these explicit host changes.
- [x] Detect actual SSH listener ports and preview all UFW changes before enabling the firewall.

## Unified Operations and Alerting

- [x] Add a unified human status dashboard and stable `sb status --json` output.
- [x] Add protected Telegram, WeCom, and generic Webhook delivery with per-cycle traffic threshold deduplication.
- [x] Add node remarks, region, purpose, line, tags, and CLI filtering without affecting generated configuration.
- [x] Add optional systemd/OpenRC health checks for services, listeners, certificates, firewall components, and traffic rules.

## Scriptability and Batch Operations

- [x] Standardize global JSON, confirmation, dry-run, quiet, and no-color CLI options with stable exit codes.
- [x] Add redacted config validation/diff previews and mutation dry-run paths.
- [x] Add non-secret node templates and atomic tag/region batch enable/disable operations.
- [x] Add resource/security threshold metrics and low-risk-only automatic repair.
