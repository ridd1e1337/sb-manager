# State schema v2

Simplified example:

```json
{
  "schema_version": 2,
  "manager_version": "0.1.0-alpha.63",
  "settings": {
    "log_level": "info",
    "default_server_address": "edge.example.com",
    "outbound_ip_strategy": "prefer_ipv4",
    "core_channel": "stable",
    "core_update_policy": "notify",
    "manager_auto_update": true,
    "manager_update_minute": 47
  },
  "tunnel": {
    "mode": "fixed",
    "node_id": "vm-cf-main",
    "domain": "cdn.example.com",
    "client_address": "cdn.example.com",
    "protocol": "http2"
  },
  "nginx_stream": {
    "enabled": true,
    "backend": "sing-box",
    "listen": "::",
    "port": 443,
    "routes": [
      {"node_id": "any-main", "sni": "edge.example.com", "backend_port": 20000}
    ]
  },
  "notifications": {
    "enabled": true,
    "provider": "telegram",
    "traffic_thresholds": [80, 90, 100]
  },
  "health": {
    "enabled": true,
    "certificate_warn_days": 21,
    "resources": {
      "disk_min_free_percent": 10,
      "inode_max_percent": 90,
      "memory_max_percent": 90,
      "cpu_load_per_core_max": 2,
      "file_descriptors_max_percent": 80,
      "fail2ban_banned_warn": 10,
      "service_restart_warn": 3
    }
  },
  "certificates": [
    {
      "domain": "edge.example.com",
      "provider": "acme.sh/dns_cf",
      "key_type": "ec-256",
      "certificate_path": "/etc/sb-manager/certs/edge.example.com/fullchain.pem",
      "key_path": "/etc/sb-manager/certs/edge.example.com/key.pem"
    }
  ],
  "nodes": [
    {
      "id": "any-main",
      "protocol": "anytls",
      "metadata": {
        "remark": "primary edge",
        "region": "hk",
        "purpose": "production",
        "line": "cn2",
        "tags": ["primary", "tls"]
      },
      "traffic": {
        "configured": true,
        "enabled": true,
        "quota_bytes": 107374182400,
        "quota_mode": "total",
        "reset_day": 1,
        "upload_rate_bps": 20000000,
        "download_rate_bps": 100000000
      },
      "users": [
        {"id": "default", "name": "AnyTLS", "enabled": true}
      ],
      "singbox": {
        "inbound": {"tcp_fast_open": true},
        "outbound": {"tcp_multi_path": true}
      }
    }
  ]
}
```

Protocol credentials are excluded from the state file. User credentials live under `secrets/users/<node-id>/<user-id>.json`; protocol-level credentials live under `secrets/nodes/<node-id>.json`.

Cloudflare API credentials remain in `secrets/dns-cloudflare.env` (0600).
Adding an enabled TLS node without a usable certificate prepares DNS-only
A/AAAA records for the detected public addresses before DNS-01 issuance.
The operation snapshot contains a `cloudflare-dns.json` journal (0600), written
before each create request. Rollback attempts to delete only records bearing
that operation's random comment and unchanged connection fields. Existing
records are reused only when they already match; conflicts are never replaced.
Remote cleanup failures are reported with the journal path for recovery.
Successful DNS records live in Cloudflare; restoring local state or deleting
a node does not remove them. The state schema version remains 2.

`settings.manager_auto_update` defaults to `true` only when missing/null;
explicit `false` survives normalization and upgrades. `manager_update_minute`
is an integer 0–179, generated once and retained, representing minutes after
03:00 in the host's local timezone. Since alpha.63 these fields control both
manager scripts and Caddy when `.caddy.managed == true`, using the same daily
task and independent update transactions. No Caddy enrollment is implicit.
`core_update_policy` and `cloudflared_update_policy` remain independent.
Last-attempt state and logs live under `var/updates/`, not in topology state.

Explicit VPS initialization is a host operation and does not add topology
fields or change the schema version. Its protected `var/vps-init/last.json`
records the completion timestamp, manager version, SSH ports and backup path.
Per-operation host configuration/service before-images live in that directory;
they are separate from node state rollback. Ordinary installation and upgrades
never execute VPS initialization without the explicit `--init-vps` option.

Alpha.57 reorganizes panel navigation, adds Sub-Store onboarding and system
support information, and prioritizes native Surge entries when sharing Snell.
It adds no state fields or migrations. Generated export files remain derived
artifacts; Snell credentials and the schema version remain unchanged.

Notification provider choice and thresholds are non-secret state. Telegram tokens/chat IDs and Webhook URLs live only in `secrets/notifications.json` with mode `0600`. Delivery deduplication and the last health report are runtime journals under `/var/lib/sb-manager/`.

Snell nodes require a sing-box 1.14.0-rc.1 or newer core. `snell_version` is 5 or 6 (existing schema-v2 nodes normalize to 5; new nodes default to 5). Version 5 uses `obfs_mode`/`obfs_host` and exports a compatible v4 client; version 6 uses `snell_mode` (`default`, `unshaped`, or `unsafe-raw`) and requires sing-box 1.14.0-rc.2 or newer. Their protocol-level secret stores the server `psk`; each user secret stores a Snell `userkey`.

Snell `credential_mode` is `single` or `multi`. Adding a second user changes it
to `multi` permanently; disabling or deleting users never changes it back.
Single-user rotation replaces both the node PSK and userkey; multi-user rotation
replaces only the selected userkey. A `single` node must have exactly one user.

Snell and ShadowTLS nodes carry `credential_revision:1`. New Snell nodes always
start at revision 1, so routine manager updates do not rotate their credentials;
only explicit rotate commands do. Missing/zero revision identifies legacy
credentials. Under the manager lock, migration snapshots state, secrets, config
and subscriptions, prepares new credentials, validates the candidate
with the real installed core, installs it and publishes live feeds; failure restores
the snapshot. Legacy Snell PSKs rotate once, including nodes with deleted former
users. Existing total user count determines the initial mode. Migration is deferred
until the core is available, and backup restoration applies the same preparation.

ShadowTLS node secrets hold `shadowsocks_server_password`; user secrets hold the
outer `password` and independent `shadowsocks_password`. The inner method is fixed
at `2022-blake3-aes-128-gcm` with 16-byte base64 keys. Its generated inbound uses
`in-<id>:ss`, listens on `127.0.0.1:0` and receives the outer inbound's detour.
Exports use the ordinary user proxy tag for the inner SS outbound and append
`:tls` for the outer ShadowTLS outbound. Both outbounds are required. These
generated tags and internal ports are not independent persistent nodes.

Hysteria2 nodes may set `obfs.type` to `salamander` or the sing-box 1.14-only `gecko`. Gecko stores `min_packet_size` and `max_packet_size` in the node state (defaults 512 and 1200); its password remains in the protected node secret. `disable_chrome_parrot` controls the 1.14 Hysteria2 client fingerprint option and defaults to `false`. `bbr_profile` accepts `conservative`, `standard`, or `aggressive`; `brutal_debug` enables Hysteria Brutal diagnostics. Enabled nodes using these 1.14 options require sing-box 1.14.0-rc.1 or newer.

Multiple TLS nodes may reference the same `certificates[].domain` and certificate files. Certificate identity is independent from listener binding; transport/port validation still prevents two direct TCP listeners from using the same port.

Every node has a normalized `traffic` object. `configured` distinguishes a never-configured node from a disabled policy; `enabled` controls runtime rules without discarding policy or usage. `quota_bytes` and either directional rate may be `null` for unlimited. `quota_mode` is `total` (upload plus download) or `download`; `reset_day` is an integer from 1 through 28 and is evaluated in UTC. Rate values are stored as bit/s. Accumulated counters are runtime data and live in `/var/lib/sb-manager/traffic-usage.json`, not in state or generated sing-box configuration.

`nginx_stream` retains its historical key for TCP/SNI mux backends.
`backend` is `sing-box`, `nginx`, `caddy`, or `nginx-site`. The `caddy` backend represents an
operator-owned Caddy L4 frontend: the manager renders loopback node listeners,
exports the public port, and observes `caddy.service` (`caddy` on OpenRC).
It does not install, stop, rewrite or reload Caddy. `sb mux caddy` emits a
listener-wrapper snippet to integrate into that frontend after route changes.
New empty configurations default to
`sing-box`; legacy configurations missing `backend` keep `nginx` when enabled
or when any routes were saved. Explicit choices survive upgrades and disabling.
Older schema-v2 files without this section normalize to a disabled empty mux.

`nginx_stream.website` is optional. When `managed:true`, it stores the website
server (`nginx`/`caddy`), actual config/binary paths, init backend, optional
service override and stream module paths, plus reserved `website_port` and
`relay_port`. The frontend stays enabled at port 443 even without active nodes.
Routes are derived from enabled SNI-capable nodes on each candidate operation;
existing route backend ports are reused. `nginx-site` uses the host's Nginx
service rather than the separate sb-manager Nginx service.

The website source files remain operator-owned. Protected host journals under
`var/website-mux/` store original file contents and installed hashes; operation
snapshots hold immediate before-images. These journals are recovery metadata,
not generated sing-box configuration or topology state. A detach verifies
installed hashes and restores the original frontend/mux selection. Cross-host
restore of managed website settings is refused, and external manual changes
must be merged before detach. Plain `caddy` states without `managed:true`
retain alpha.53's manual synchronization behavior.

The optional top-level `caddy` object records explicit program lifecycle
enrollment: `managed:true`, canonical `binary`, immutable `target`, `config`,
`init`, `method` (`debian-alternatives` or `standalone`), `service_file`, formal
`version`, `sha256`, and nullable `previous:{target,version,sha256}`. Debian
enrollment uses the publisher's diversion/alternatives convention; other
systems retain the package binary and use a separate managed link. Package
and service before-images are journaled under the operation snapshot's
`caddy-package/`. These are recovery metadata, not disposable build cache.
State restoration without that package journal requires matching lifecycle
metadata so it cannot point at a different host package state. No schema
version change or credential rotation is introduced.

Retention epochs and last-run metadata live in `var/maintenance/`, outside
topology state. Cleanup only owns known temporary downloads/builds and log
files. It never purges credentials, certificates, subscriptions, rule data,
manual backups, website recovery journals or the current/previous Caddy binary.

`nginx_stream.routes` separates the public frontend from sing-box's runtime listener. A node keeps its original direct `listen`/`port`; while the mux is enabled, rendering substitutes `127.0.0.1:<backend_port>` and exports substitute the shared public port. Node IDs, case-insensitive SNI values, and backend ports must each be unique. The built-in backend adds a TCP-only direct inbound, scoped TLS sniffing, fixed loopback route destinations and a final reject for that inbound. It adds no credentials and does not terminate TLS. API, subscriptions, Realm, Sub-Store and node port reservations are checked before applying a candidate.

The optional top-level `realm` object configures sing-box's `hysteria-realm` service. Its bearer token is stored only in `secrets/realm.json`; `realm.public_url` is used by Hysteria2 inbound/outbound `realm` blocks. A Hysteria2 node opts in with `realm_enabled`/`realm_id`, and may restrict Realm traffic to IPv4/IPv6 or request UPnP/NAT-PMP port mapping. Realm cannot be disabled while an enabled Hysteria2 node still references it.

Existing v1 installations migrate once, before rendering, with a pre-migration snapshot. Future changes must use explicit, one-way migration steps. Generated config files must never be parsed back into state.

`nodes[].metadata` contains operator-only `remark`, `region`, `purpose`, `line`, and unique `tags`. These values are for filtering and dashboards and are deliberately excluded from protocol renderers and client exports.

`node_templates` stores non-secret protocol defaults captured from existing nodes. Templates never include user or node credentials; creating a node from a template generates fresh credentials through the normal node-add transaction.

`nodes[].singbox.inbound` and `nodes[].singbox.outbound` are optional JSON
objects for fields introduced by newer sing-box releases. They are accepted by
`sb node add` and `sb node set` through `--sing-box-inbound-json` and
`--sing-box-outbound-json` (or `@FILE`), merged into generated server and client
objects, and checked by the installed core. The manager keeps `type`, `tag`,
addresses, ports, users, and credentials authoritative. Compound protocol
exports can use an optional `by_tag` object to target a generated member by its
tag; otherwise an array extension applies to the primary member.

Mutations hold the manager lock through candidate validation, rendering,
installation, and service reconciliation. A failed operation restores the
state/config pair plus secrets, certificates, subscriptions, and service
definitions from the operation snapshot. Core upgrades additionally retain a
known-good binary/config pair for compatibility-aware rollback.


## Live subscriptions (alpha.34)

Live subscriptions (alpha.34) keep authorization metadata in protected
`subscriptions/<token-sha256>.meta.json`: `live` defaults to false for old
files, and `expires_at_epoch: null` is valid only for live subscriptions.
`subscriptions/live.json` is an atomic derived bundle of current Sub-Store
links and mixed/TUN profiles. State and protected node secrets remain the
source of truth. Full backups include metadata and generations; restored live
content is regenerated after the restore transaction. Remote source URLs and
collection definitions belong to the protected Sub-Store database and its
backups, never to public status output.

## Optional operations (alpha.32)

Existing v2 states remain valid; no destructive migration is required. The
`socks`, `http`, and `mixed` node protocols store authenticated user secrets as
`{username,password}` in the existing protected user-secret files. Their default
listener is `127.0.0.1`.

A node may have `expiry:{at:null|UNIX_SECONDS,suspended:false,resume_enabled:false}`.
The expiry tick records the previous enabled state when suspending a node;
renewal restores that state, while manual disable cancels automatic resumption.

`traffic_groups` is an optional array of `{id,nodes:[NODE_ID],quota_bytes,
quota_mode,reset_day}`. Members must have traffic accounting enabled and cannot
belong to two groups. Group counters live in `traffic-usage.json.groups`, using
the same cycle/upload/download fields as node counters, and survive membership
changes. Group and node billing cycles are independent.

`shaping:{enabled,interface,capacity_bps}` configures optional downstream tc
shaping. Original qdiscs and the last applied plan are protected runtime recovery
files in `var/shaping`; they are specific to the host interface, not generated
sing-box configuration.

Tunnel mode `managed` adds `tunnel_id` and `routes:[{id,hostname,service,path}]`.
The credential is stored separately as `secrets/cloudflared-credentials.json`.
Generated ingress JSON has a final 404 rule; it is not persistent input state.

`substore:{enabled,port,version,frontend_version}` describes the optional service.
Its random API path is in `secrets/substore.json`; app and mutable data reside
under `var/substore`. Full backups include those directories. Restore operations
snapshot component payloads for rollback; ordinary node snapshots avoid copying
large unrelated component data.
