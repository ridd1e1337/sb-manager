# Changelog

## Unreleased

## 0.1.0-alpha.47

- Make the original complete node wizard the default main-menu entry again;
  `sb quick` now opens the same wizard as a compatibility alias.
- Remove the separate quick-creation implementation and its duplicate option
  flow, reducing the number of ways to add a node without removing protocol,
  certificate or import features.
- Synchronize the user guide and architecture notes. Static checks only; no
  test scripts or procedures were added.

## 0.1.0-alpha.46

- Shorten the common panel wording for the main menu, node selection,
  certificate flow, quick creation, updates and TCP/443 sharing. Keep advanced
  settings available only when requested.
- Preserve all existing commands and behavior; this release only simplifies
  operator-facing text. Static checks only; no test scripts or procedures were
  added.

## 0.1.0-alpha.45

- Add one-step multi-node TCP/443 setup from the panel and `sb mux auto`, with
  automatic SNI route/backend allocation and one transactional enable.
- Refuse a frontend bind when Caddy, Nginx, or another non-manager service owns
  the public port; existing websites are never stopped, reloaded or rewritten.
- Document the batch workflow and safe external L4 forwarding path. Static
  checks only; no test scripts or procedures were added.

## 0.1.0-alpha.44

- Expand the quick node wizard with an explicit protocol advanced-settings
  step. Hysteria2 now exposes Salamander/Gecko, packet sizes, BBR profile,
  Chrome QUIC fingerprint, Brutal debug and Realm; other quick protocols expose
  their supported encryption, security, congestion and Snell version options.
- Make certificate protocols clearly accept a new domain for reuse or issuance
  inside the same flow; keep the full protocol wizard available with `a`.
- Synchronize quick-start documentation. Static checks only; no test scripts or
  procedures were added.

## 0.1.0-alpha.43

- Add a sing-box-native TCP/SNI frontend using scoped TLS sniffing, fixed
  loopback routes and a final reject for unknown traffic. No extra binary,
  package or daemon is needed; backend TLS and certificate verification remain.
- Default new mux configurations to sing-box while preserving existing Nginx
  routes and explicit backend choices. Add CLI/panel backend switching within
  the existing candidate validation and rollback transaction.
- Reuse public-port exports, live subscriptions, loopback traffic accounting,
  restore and disable behavior. Make status, health, logs and repair aware of
  the selected backend and extend port reservations to local service listeners.
- Document Alpine resource expectations, migration and TCP-only scope.
  Only static checks were performed; no test scripts or procedures were added.

## 0.1.0-alpha.42

- Unify Enter as back across menu choices, certificate and resource selectors,
  protocol options, creation confirmation, and client export modes. Empty new
  IDs, member selections and certificate domains can leave the current action.
- Return from result pages to the main menu on Enter; require `r` to remain
  in the current menu. Propagate this return through nested worker processes.
- Keep the main menu waiting on Enter, including installations without nodes,
  and require explicit selection for node creation or panel exit.
- Preserve valid field defaults after invalid edits and synchronize navigation
  documentation. Static checks only; no test scripts or procedures added.

## 0.1.0-alpha.41

- Make Enter return from node selection instead of selecting the first node,
  preventing repeated navigation in node management and repeated share/export
  actions when pressing Enter. Manual node-ID entry also returns when empty.
- Clarify the node-selection prompt and document the navigation behavior.
  Validation is limited to static checks; no test scripts or procedures added.

## 0.1.0-alpha.40

- Enable daily manager-script updates by default on first upgrade and fresh
  installs; preserve explicit opt-outs and a per-server staggered local time.
- Add systemd timer and OpenRC/dcron scheduling, panel controls, status, manual
  runs, protected attempt records and two rotating logs. Failed scheduled
  attempts retry the next day; update/uninstall operations share a lock.
- Reconcile scheduling across installation, restore and uninstall, and retain
  --no-start behavior. Alpine installs dcron when the default scheduler needs it.
- Fix --keep-core entering the core download path; manager updates retain the
  installed sing-box binary. Bound source archive download time.
- Update state and operator documentation. Only static checks were performed;
  no test scripts, environments or procedures were added.

## 0.1.0-alpha.39

- Add `sb quick` and a guided node-creation path with protocol presets,
  suggested addresses/ports, and an editable summary before creation.
- Issue or renew certificates inside the node workflow, reusing saved DNS
  credentials and preserving cancellation/failure handling in separate workers.
- Deliver links and available QR codes immediately after creation; keep a
  completion page for import, subscription, node management and firewall access.
- Export complete per-user sing-box profiles alongside outbound fragments,
  retaining both ShadowTLS outbounds and publishing validated files atomically.
- Keep advanced protocol options available and reject creation in dry-run mode.
  No test scripts, environments or procedures are added; checks are static only.

## 0.1.0-alpha.38

- Rotate the actual Snell PSK for single-user credentials and persist multi-user
  authentication after users are disabled or deleted; never fall back to PSK-only
  authentication based on the enabled-user count.
- Compose ShadowTLS v3 with an authenticated Shadowsocks 2022 inner inbound,
  independent per-user inner keys, loopback binding, and matching client detours.
  Export plugin-aware SS links and include both outbounds in profiles and feeds.
- Upgrade legacy protocol credentials inside the existing snapshot/rollback
  transaction, including backup restore and live subscription publication.
  Legacy Snell PSKs rotate once; affected clients must re-import credentials.
- Update protocol security and state documentation. No test infrastructure or
  procedures are added; validation for this change is limited to static review.

## 0.1.0-alpha.37

- Remove the development test suite, fixtures, test-host instructions,
  acceptance records, and tested-core release metadata.
- Remove test-only installation paths, fake component installation, root-check
  bypasses, and filesystem/setup fault injection switches. Preserve production
  diagnostics, configuration validation, and transactional rollback.
- Record the policy against adding test scripts, environments, or procedures.
- Document protocol security boundaries, incomplete ShadowTLS composition,
  Snell PSK rotation/revocation limitations, and plaintext proxy/Realm risks.
  These protocol limitations remain unresolved by this cleanup.

## 0.1.0-alpha.36

- Preserve explicit AnyTLS certificate verification through Sub-Store V2Ray
  URI conversion with `allowInsecure=0` alongside `insecure=0`; explicitly
  export `tls.insecure=false` in sing-box profiles.
- Document how Sub-Store collection quick settings can override secure source
  links, and how to restore source verification before refreshing v2rayN.

## 0.1.0-alpha.35

- Migrate repository, installation and update URLs to ridd1e1337 on GitHub.

## 0.1.0-alpha.34

- Add opt-in live subscriptions with stable token URLs, finite or revocable
  non-expiring access, ID-based revocation, and optional HTTPS entry URLs.
  Existing snapshot subscriptions retain their original behavior.
- Publish one atomic live generation after successful state transactions;
  node/user changes and credential rotation update both sing-box profiles and
  Sub-Store links. Publication failure rolls back the state transaction.
- Change Sub-Store node synchronization to a reusable live source, and add
  remote source registration, checks, removal, and automatic collection
  membership. Preserve source processors and collection order/settings;
  failed registration restores previous definitions where the API is available.
- Add panel controls for remote sources and live subscription creation/status/
  revocation. Bypass source caching so client subscription refreshes retrieve
  current nodes; Sub-Store is only required on the aggregation server.

## 0.1.0-alpha.33

- Keep panel pages open after actions, cancellations, and failures; preserve
  the selected node and return one submenu level at a time. Validate menu
  choices, support q to cancel ordinary input, and exit cleanly on EOF.
- Run panel actions in fresh Bash workers so backend failures stop execution
  without terminating the menu. Reload after manager updates, exit after
  completed uninstall, and preserve global execution/color options.
- Add numbered selectors for quota groups, members, interfaces, Tunnel routes,
  and compatible benchmark records, with readable operation summaries.
- Retain existing node/group/route/settings values and Sub-Store ports during
  edits; allow clearing optional metadata and route paths. Suggest available
  proxy ports and listener-aware client addresses.

## 0.1.0-alpha.32

- Add bounded iperf3 throughput tests, protected history, and comparison of
  runs with matching endpoints, direction, duration, and stream count.
- Add authenticated SOCKS5, HTTP, and mixed nodes with loopback defaults,
  multi-user credentials, exports, templates, and panel controls. Block dynamic
  SOCKS UDP forwarding when port-based traffic policies are enabled so it
  cannot bypass node or shared quotas.
- Add node expiry/renewal with scheduled suspension, preserved credentials,
  and deduplicated expiry notifications.
- Add shared node quotas with independent billing cycles, nftables enforcement,
  retained group usage, backups, and threshold alerts.
- Add optional tc HTB/fq_codel shaping for direct-node downstream traffic on
  one selected interface, with queue ownership checks and restore support.
- Add locally managed Cloudflare credentials and multi-host/path ingress
  routes validated by Cloudflared before service activation.
- Add native Sub-Store frontend/backend installation with verified Release
  digests, systemd/OpenRC services, node synchronization, transactional updates,
  dedicated backups, and integration with full manager backups.

## 0.1.0-alpha.31

- Add bandwidth/RTT-based TCP buffer planning and tuning with memory/cgroup
  caps, readback verification, protected backups, retryable rollback, restore,
  conflict reporting, CLI JSON/dry-run output, and panel controls.
- Add bounded IPv4/IPv6 latency, packet-loss, and RTT-jitter diagnostics using
  local iputils/BusyBox ping, with JSON output and a panel entry.
- Keep TCP tuning independent of BBR and Hysteria2 UDP settings; restore its
  original values before uninstalling. Support Alpine/BusyBox/OpenRC alongside
  Debian/systemd without changing proxy state or installing another kernel.

## 0.1.0-alpha.30

- Export single-user Snell v5 to Surge, mihomo, sing-box, and Sub-Store, and
  make v5 the compatibility-first default for newly created nodes.
- Export single-user Snell v6 to supported Surge Beta/TestFlight and sing-box
  clients while clearly excluding unsupported mihomo targets.
- Print copyable Sub-Store single-node entries and serve a dedicated mixed
  Sub-Store subscription format instead of relying on unsupported `snell://`
  parsing.
- Add a real local Snell end-to-end handshake to `sb probe` and print the
  required Surge Beta/TestFlight version and cloud TCP-port reminder for v6.
- Fix manager self-updates started from an installer-launched interactive panel
  failing against the setup lock inherited from their own parent installer.

- Add `sb update --check` and `sb update` for self-updating the manager while
  preserving nodes, secrets, certificates, backups, and the current core.
- Make repeated installs reuse the existing core by default when the requested
  version is unchanged, and add the internal `--keep-core` upgrade path.
- Record the immutable source commit and repository during bootstrap so update
  checks are reproducible.

- Fix Alpine/BusyBox bootstrap installs exiting while resolving the latest
  commit because `grep|head` could trigger a SIGPIPE under `pipefail`.
- Fix Alpine/OpenRC services failing to bind port 443 on VPS/container kernels
  that expose file capabilities but do not apply them to unprivileged users.
- Fix Alpine status checks missing listeners whose `ss -p` process name is the
  gcompat dynamic loader (`ld-musl`/`ld-linux`).

- Resolve the default sing-box version from the newest non-draft GitHub
  Release at install/update time; use the verified `1.14.0-rc.4` asset map
  only when the Release API is unavailable.
- Make Alpine installation default to a disk-friendly `minimal` dependency
  profile; defer Python, nftables, kmod, dcron, Nginx, and other optional
  components until the corresponding feature is used.
- Stop downloading Cloudflared during normal installation. Add explicit
  `sb cloudflared install|status` commands and retain existing Tunnel
  installations across upgrades.
- Bound cached core and program-upgrade backups and add free-space checks before
  large core downloads.
- Add the complete Go `sb-manager-web` project development specification, including repository boundaries, CLI integration, Web API, Agent enrollment, security, deployment and phased milestones.
- Start the independent Go `sb-manager-web` repository with SQLite storage, embedded WebUI, local/remote task APIs, Agent enrollment, and systemd/OpenRC deployment.
- Make the default installation and `sb core update` resolve the newest non-draft GitHub sing-box Release (including prereleases); retain `--core-version` for reproducible pinning.
- Add one-click BBR enable/status/restore commands and panel controls with transactional sysctl backup and rollback.
- Add one-click Hysteria2 UDP buffer tuning (`rmem_max`/`wmem_max` 16 MiB) with panel/CLI status, backup, restore, and rollback.
- Raise the default sing-box core from 1.14.0-rc.1 to 1.14.0-rc.2 so new Snell v6 nodes work immediately after installation.
- Add sing-box 1.14 Hysteria2 Gecko obfuscation with configurable packet sizes and the Chrome QUIC fingerprint switch.
- Add `sb core schema [FILE]` and an interactive panel action for exporting the schema generated by the installed 1.14 core.
- Add 1.14 optimistic DNS caching and per-query DNS timeout settings with CLI/panel controls and 1.13-safe rendering.
- Expose Hysteria2 1.14 BBR profiles and Brutal debug logging in the node wizard, templates, and client exports.
- Add a loopback-safe `sb api cli` wrapper and a corresponding API/Dashboard panel menu.
- Add 1.14 TUN DNS mode/address controls to client exports and the interactive panel, while retaining 1.13-safe defaults.
- Add `sb core capabilities [--json]` and a panel view of sing-box build tags and compiled 1.14 feature support.
- Document the complete 1.14 feature coverage matrix and the separate-model boundary for Realm/VPN/desktop-only features.
- Add Snell v6 traffic-shaping mode with v5 compatibility selection, version-aware exports, migration defaults, and panel/CLI controls.
- Add Hysteria Realm rendezvous service with protected token storage, TLS/loopback configuration, Hysteria2 node linkage, NAT traversal options, panel controls.

## 0.1.0-alpha.27

- Standardize script-facing global CLI options (`--json`, `--yes`, `--dry-run`, `--quiet`, `--no-color`) and usage-error exit code 2.
- Add `sb config validate|diff` with redacted candidate previews and dry-run support for node and traffic policy edits.
- Add non-secret node templates plus atomic tag/region batch enable/disable operations.
- Add resource metrics (disk, inode, memory, load, file descriptors, Fail2ban bans, service restarts) and feed threshold/security changes into the existing notification channel.
- Add certificate-renewal failure notifications and `sb doctor --repair-safe` / `sb repair --safe` low-risk recovery.

## 0.1.0-alpha.26

- Add a unified `sb status` dashboard and machine-readable `sb status --json` output covering services, nodes, traffic, certificates, firewall, notifications, and health issues.
- Add protected Telegram, WeCom, and generic Webhook notifications with deduplicated traffic quota thresholds and periodic health-change alerts.
- Add SSH listener discovery, UFW change preview/safe setup, and automatic allowance of detected SSH ports alongside web and protocol ports.
- Add node metadata (remark, region, purpose, line, tags) with CLI/panel editing and tag/region filtering.
- Add optional systemd/OpenRC periodic health checks with certificate expiry, listener, service, firewall, Fail2ban, and nftables diagnostics.

## 0.1.0-alpha.25

- Add explicit firewall-panel and CLI setup for Fail2ban SSH protection (180-second window, five failures, permanent bans) and UFW installation/enablement with TCP 22, 80, 443, and active protocol ports allowed.
- Snapshot existing iptables/UFW status and Fail2ban configuration before setup, with idempotent component status reporting and Debian/RPM/Alpine/OpenRC package-manager coverage.

## 0.1.0-alpha.24

- Add node-level upload/download accounting, UTC monthly total/download quotas, and directional nftables rate ceilings without taking over the host's `tc` qdisc.
- Persist traffic policy in normalized schema-v2 node state and accumulated usage in a protected journal, with transactional rollback, backup/restore, systemd/OpenRC boot recovery, periodic checkpoints, diagnostics, CLI, and panel integration.

## 0.1.0-alpha.23

- Extend Nginx Stream SNI multiplexing to Alpine/OpenRC with `apk` dependency installation, supervised foreground service output, persistent low-port capability handling, and OpenRC diagnostics/rollback/uninstall coverage.

## 0.1.0-alpha.22

- Include the setup-time Snell renderer load fix.

## 0.1.0-alpha.21

- Make sing-box 1.14.0-rc.1 the primary core and resolve latest core updates from the newest official release, including prereleases.
- Add explicit firewall/port management commands for protocol port inspection, UFW allow rules, and backed-up INPUT deny cleanup.

## 0.1.0-alpha.20

- Include the final Snell preview-core fixes in the published release.

## 0.1.0-alpha.19

- Generate random persistent Naive usernames for new users and credential rotations while preserving existing usernames until rotation.
- Add Snell v5 node provisioning with per-node PSK, per-user userkeys, optional HTTP obfuscation, client exports, and 1.14+ core gating.

## 0.1.0-alpha.18

- Default AnyTLS client exports and share links to Chrome uTLS fingerprint (`chrome`).
- Default new Shadowsocks 2022 nodes to `2022-blake3-aes-256-gcm` in both the panel and CLI.

## 0.1.0-alpha.17

- Fix Naive inbound authentication to use each user's protocol username instead of the display name, matching generated `naive+https://` links and client outbounds.

## 0.1.0-alpha.16

- Default VLESS Reality SNI and handshake target to `www.apple.com` while retaining custom domain prompts and CLI values.

## 0.1.0-alpha.15

- Use the numbered node selector for the panel's share-link and client-export action, with an explicit all-nodes option.
- Document certificate reuse separately from listener-port reuse and clarify the direct TCP/UDP and Nginx Stream constraints.

## 0.1.0-alpha.14

- Keep Reality SNI and ShadowTLS handshake targets separate from the client endpoint: omitted endpoints now use the detected public IPv4.

## 0.1.0-alpha.13

- Apply the selected outbound IP strategy to both server direct outbounds and exported client configurations.

## 0.1.0-alpha.12

- Prefer a node's configured domain as the default client address; address-only nodes now default to the detected public IPv4.
- Replace manual node-ID hunting in the panel with numbered node selection while retaining manual ID entry.
- Add global client outbound IP strategies: IPv4 preferred, IPv6 preferred, and IPv4 only.

## 0.1.0-alpha.11

- Show valid issued certificates as numbered choices when adding AnyTLS, Hysteria2, Trojan, TUIC, VLESS TLS, and NaiveProxy nodes.
- Default to the first available certificate while retaining manual domain entry and a cancel option.
- Ask for the VLESS security mode before requesting a TLS certificate or Reality SNI.

## 0.1.0-alpha.10

- Use the managed ACME home/config/certificate directories for issue, install, and renewal operations instead of silently falling back to `/root/.acme.sh`.
- Migrate existing root-owned acme.sh domain material and account metadata during upgrade, while keeping Cloudflare credentials in the sb-manager secret file.
- Treat acme.sh's exit code 2 for an in-window renewal skip as an idempotent issue operation.

## 0.1.0-alpha.9

- Fix an ACME deployment deadlock caused by the reload hook re-entering `state_init` while certificate issuance held the manager lock.
- Fix strict-shell expansion in `cert hook` and `cert inspect`, and add bounded issue/install/cron timeouts with transactional rollback.

## 0.1.0-alpha.8

- Add optional Debian/systemd Nginx Stream SNI passthrough for sharing one public TCP port across AnyTLS, Trojan, VLESS TLS/Reality, Naive TCP, and ShadowTLS v3.
- Move routed sing-box listeners to unique loopback backends while preserving their direct ports for lossless disable/rollback and publishing the mux port in links and client exports.
- Add CLI/panel management, strict SNI/route validation, unknown-SNI rejection, systemd sandboxing, diagnostics, backup compatibility, and transactional activation rollback.

## 0.1.0-alpha.7

- Add Trojan TLS, TUIC, VLESS TLS/Reality, NaiveProxy, and ShadowTLS v3 protocol modules with per-user credentials and validated client exports.
- Add schema-v2 state migration, transactional rollback across state/config/secrets/certificates/subscriptions, hardened restore checks, and optional age-encrypted backups.
- Add loopback-only expiring subscriptions, gated sing-box 1.14 API/Dashboard support, complete mixed/TUN exports, public-address source tracking, and `sb probe` network diagnostics.
- Pin remote bootstrap installs to an explicit immutable ref and add release provenance, checksum, and optional GPG signature artifacts.

## 0.1.0-alpha.6

- Retry all core download failures with bounded backoff instead of relying on curl's limited default retry classes.
- Stop immediately after a failed or empty download and remove partial files before checksum or extraction steps.
- Validate GitHub Release API responses and propagate lookup failures without silently converting `latest` into an invalid version.

## 0.1.0-alpha.5

- Allow `AF_NETLINK` in the hardened systemd address-family policy so sing-box can subscribe to Linux route updates during startup.
- Add a real transient systemd startup preflight using the rendered sing-box configuration; the previous `version` check could not detect route-monitor failures.
- Extend `sb doctor` with an explicit AF_NETLINK policy check and extend `sb repair` with the real startup preflight.

## 0.1.0-alpha.4

- Fix systemd `203/EXEC` / `Permission denied` failures caused by stale sing-box file capabilities left by an OpenRC-style installation or migration.
- Make sing-box capability handling backend-specific: systemd receives `CAP_NET_BIND_SERVICE` only through the unit, while OpenRC keeps the minimal file capability.
- Add a transient systemd sandbox preflight before starting the permanent service, using the same critical user, capability and hardening properties.
- Stop an existing restart loop before replacing service definitions and limit repeated systemd startup failures to five attempts per minute.
- Extend `sb doctor` and `sb repair` to detect, explain and safely repair file-capability, path-permission, mount and systemd sandbox execution problems.
- Ensure core download, update, switch and rollback all normalize executable permissions and capabilities for the active service backend.

## 0.1.0-alpha.3

- Add Alpine Linux 3.21-3.24 support with the native OpenRC service manager and `apk` dependency installation, including `gcompat` for the official sing-box Linux core.
- Add a systemd/OpenRC service abstraction for start, stop, enable, status, logs, repair, Tunnel management, and uninstall.
- Add OpenRC supervised services for sing-box and cloudflared, plus `dcron` periodic jobs for core updates, ACME renewal, and Quick Tunnel refresh.
- Keep sing-box unprivileged on OpenRC by applying only `cap_net_bind_service` to installed cores for low-port listeners.
- Add portable account/group, DNS lookup, and certificate-expiry helpers for musl/BusyBox environments.

## 0.1.0-alpha.2

- Fix first installation requiring a second run: download progress logs no longer contaminate the binary path captured by command substitution.
- Validate generated sing-box/cloudflared symlink targets before installation continues.
- Repair non-traversable core directories so the low-privilege `sbmanager` account can execute the cores.
- Treat an inactive sing-box service as normal when no nodes are enabled; the first enabled node starts it automatically.
- Fix `sb doctor` exiting at its first warning/failure under `set -e`, and add detailed permission/service diagnostics plus `--repair`.
- Add interactive normal and full-uninstall options, plus `--yes` automation.

## 0.1.0-alpha.1

Initial alpha release.

- State-driven sing-box configuration generation
- VMess-WS with Cloudflare Tunnel
- Shadowsocks 2022
- AnyTLS
- Hysteria2
- acme.sh Cloudflare DNS-01 certificate management
- Core update and rollback
- Interactive `sb` panel and CLI
- Backup, restore, export, logs, and diagnostics
