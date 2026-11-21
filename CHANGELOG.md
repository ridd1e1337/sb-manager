# Changelog

## Unreleased

## 0.1.0-alpha.113

- 服务器换公网 IP（域名不变）后的处理：
  - `sb settings refresh-ip` 与面板“核心通用设置 → 服务器换了 IP”：重新探测公网 IP，把使用旧 IP 的默认地址和节点连接地址
    换成新 IP，更新本机在 Cloudflare 上的 A/AAAA 记录，并刷新分享链接、订阅和中心 Sub-Store 来源；
  - 每 15 分钟的维护任务自动检查：两个独立服务报告相同的新 IPv4 时自动执行同样的更新；DNS 未更新成功会在后续检查中重试；
  - 只改“属于本机”的 DNS 记录：带本管理器标记的，或仍指向本机旧 IP 的；指向其他服务器、开启橙云的记录不动；
  - 申请证书/接入域名时，遇到仍指向本机旧 IP 的记录会自动改指，不再报“已有指向其他地址的记录”。
  证书按域名签发，换 IP 后继续有效，无需重新申请。
- 新增 `sb cert delete 域名` 与证书菜单“删除证书”：删除证书文件并停止续签；仍被节点或网站使用时拒绝并列出使用者。

## 0.1.0-alpha.112

- 移除核心回滚：`sb core rollback` 与面板中的回滚项。磁盘上只保留正在使用的 sing-box 核心；（此前默认已只保留当前版本，现在去掉回滚入口和历史记录文件。）
  需要旧版时用 `sb core update 版本号`。升级时先用新核心校验配置、启动失败自动切回的保护不变。

## 0.1.0-alpha.111

- 不留垃圾：删除节点或用户时同时删除其导出的客户端文件（含凭据）；定期维护会清掉已不存在的节点/用户的导出目录。

## 0.1.0-alpha.110

- 性能：单节点分享的客户端文件（sing-box/Xray/mihomo 配置）按内容缓存。节点、凭据、共享设置或核心程序未变化时
  直接复用，不再重新生成；任一变化即失效。导出文件与终端输出和之前逐字节一致。

## 0.1.0-alpha.109

- 稳定性：排查全部“管道读端提前关闭”的写法（与 alpha 上一版 Sub-Store 菜单退出码 141 同类）。管道末端的
  `grep -q` 改为读完整个输入的 `pipe_has`，`head`/带 `exit` 的 awk 改为不提前退出的等价写法，避免 pipefail 下
  把“已匹配”误判为失败（例如 UFW 状态、端口占用、版本校验）或中止操作。
- 性能：分享链接按内容缓存（节点、凭据、公网入口设置任一变化即失效，带警告的结果不缓存）。`share all`、
  Sub-Store 链接导出、订阅刷新和中心 Sub-Store 推送在节点未变化时不再为每条链接重复运行约 30 次 jq；
  `share all` 不再把每条链接生成两遍。输出与之前逐字节一致。

## 0.1.0-alpha.108

- 修复：已接入中心 Sub-Store 时打开“Sub-Store 订阅管理”菜单直接中止（退出码 141）。菜单顶部的状态改用单行函数，
  不再经管道截取多行输出。
- 重新连接或更换中心 Sub-Store 时，来源名和显示名默认沿用当前值；提示改名会在中心新建来源。

## 0.1.0-alpha.107

- 移除故障诊断与修复：面板入口、`sb doctor`、`sb repair`、`sb probe` 及只为它们服务的检查函数。运行状态、
  运行日志、健康监控和操作时的配置校验与自动回滚不变。
- “VPS 与网站运维”从 10 项整理为 5 项：1 新 VPS 一键初始化（含组件状态）、2 防火墙与 SSH 防护、
  3 网站与 443 共用（REALITY 与本机网站 / 多节点 SNI 分流 / OpenList）、4 网络调优与测速、
  5 程序与缓存维护（Caddy、缓存与日志、支持的系统）。
- 彻底卸载改为 y/N 确认，不再要求输入 DELETE。
- 主菜单其后各项前移：10 运行日志、11 核心通用设置、12 VPS 与网站运维、13 节点流量与限速、14 通知与健康监控、
  15 卸载管理器、16 Sub-Store 订阅管理、17 出站、WARP 与分流。

## 0.1.0-alpha.106

- 移除“完整客户端配置”：主菜单第 5 项、节点创建后“生成完整客户端配置”入口与 `sb export config`。每个节点的分享链接、
  二维码、客户端文件（主菜单 4）和动态订阅不受影响，`sb export outbounds` 保留。
- 主菜单去掉“节点与客户端 / 维护与扩展”分组标题，成为连续列表：5 TLS 域名证书、6 CF Tunnel、7 更新管理器与核心、
  8 sing-box API 与网页仪表盘、9 Hysteria Realm、10 运行日志、11 故障诊断与修复、12 核心通用设置、13 VPS 与网站运维、14 节点流量与限速、
  15 通知与健康监控、16 卸载管理器、17 Sub-Store 订阅管理、18 出站、WARP 与分流。文档中的面板路径同步更新。

## 0.1.0-alpha.105

- 修复：Sub-Store 链接导出在分享链接为空时写入空行。

## 0.1.0-alpha.104

- 移除节点模板与批量操作：面板“节点模板与批量操作”、`sb node template list|save|delete|add`、
  `sb node enable-all|disable-all`；状态中的 `node_templates` 自动删除。`sb node clone` 保留。
- 主菜单其后各项前移：17 卸载管理器、18 Sub-Store 订阅管理，19 出站、WARP 与分流。

## 0.1.0-alpha.103

- 移除备份与恢复功能：`sb backup`、`sb restore`、面板“13. 备份与恢复”、Telegram `/backup` 与
  `sb notify bot backup on|off`（状态中的 `notifications.bot.backup` 自动删除）。操作失败时的自动回滚快照不受影响；
  `sb substore backup|restore` 仍可备份 Sub-Store 数据。
- 主菜单 13 之后的各项前移一位：13 核心通用设置、14 VPS 与网站运维、15 节点流量与限速、16 通知与健康监控、
  17 节点模板与批量操作、18 卸载管理器、19 Sub-Store 订阅管理，`20` 为出站、WARP 与分流（原 22）；旧的 21 入口移除。
- 子菜单输入超出范围时提示“先输入 0 返回上一级”，避免把主菜单编号输在子菜单里。

## 0.1.0-alpha.102

- 修复：失败操作回滚时可能误报“自动恢复未完成”。trap 中调用的函数里，裸 `return` 继承的是触发回滚的失败状态；
  现统一改为 `return $?`（trap 外行为不变）。

## 0.1.0-alpha.101

- 新增 `sb substore remote set|push|status|disable` 与面板 `20 → 13`：接入已有的中心 Sub-Store，本机不必安装
  Sub-Store。本机节点作为中心的一个本地来源推送；首次创建时设置显示名和标签，之后只更新节点内容，保留中心的改名、
  标签与处理规则。每次成功的修改操作后按节点/凭据指纹判断，有变化才在后台推送，不拖慢操作；中心不可达只记录并在
  状态中提示。后端地址仅存于 0600 secret，可从标准输入读取。

## 0.1.0-alpha.100

- sb-manager uses sing-box only. Removed every remaining Xray code path: the
  legacy Xray service/binary cleanup, the Xray-only VLESS migration marker
  (`migration`), the `sb-xray` unit handling in setup and uninstall, the
  Xray profile format of the subscription server, and Xray references in
  help, messages and docs. Normalization drops fields of other cores
  (`settings.vless_engine`, `settings.xray_update_policy`,
  `settings.xray_api_port`, `xray_routing`, `nodes[].xray`) and removes VLESS
  nodes without TLS/REALITY, which sing-box cannot run, together with their
  credentials (a warning lists them).

## 0.1.0-alpha.99

- Performance: state migration, validation and the credential check are
  skipped when the state content and manager version match the last full
  init (`/run/sb-manager/.state-ready`); read-only commands such as
  `sb node list` and `sb routing` drop from 0.35 s to 0.15 s, and every panel
  page opens faster. A changed or corrupted state is still fully checked.
- Status/health: UFW and Fail2ban are probed concurrently and resource
  metrics are computed once per page (`sb status` about 20 % faster).

## 0.1.0-alpha.98

- No leftover files: a failed state normalization no longer leaves an empty
  `.state-normalize.*` in `/etc/sb-manager`; stale dot-temp files in the config
  and secrets directories are removed under the manager lock; the Xray-era
  `xray-config-check.log` and unused `user-usage.json` are removed by the
  legacy cleanup.
- Removed 13 unused functions.

## 0.1.0-alpha.97

- Performance: the state schema and the seven module validators run
  concurrently and are checked in the original order; a failing validator is
  re-run in the foreground so its message is unchanged. Node add 2.8 → 2.5 s,
  `sb config validate` 1.2 → 1.0 s, `sb status` 1.4 → 1.2 s.

## 0.1.0-alpha.96

- Remove the unused `/run/sb-manager/vless-cache` left by alpha.81/82 during
  the legacy cleanup on load.

## 0.1.0-alpha.95

- Performance (14 nodes): node add 5.0 → 2.8 s, node delete 3.1 → 2.75 s,
  `sb config validate` 2.4 → 1.2 s, `sb share` 3.6 → 2.6 s, `sb status`
  1.7 → 1.4 s. Render reads all scalar settings in one jq call; a state
  content is fully validated once per process (it was validated up to three
  times per operation); share exports run in parallel while the link is
  shown; status and health probe UFW/Fail2ban once per page instead of up to
  six times. Outputs are unchanged.

## 0.1.0-alpha.94

- Outbounds and routing (same model as xray-manager, implemented with
  sing-box): `sb outbound add|remove|test`, `sb warp --register` (WireGuard
  endpoint), `sb balancer set` (urltest/selector groups), `sb route
  add|remove|default|strategy|test`, `sb dns set`, `sb routing`. Rules accept
  domain:/full:/keyword:/regexp:/geosite: and CIDR/geoip:; geosite/geoip use
  SagerNet remote rule-sets downloaded and cached by sing-box itself
  (`/var/lib/sb-manager/sing-box/cache.db`). Panel menu 22.
- `sb outbound sub add NAME URL`: import a remote subscription as outbounds
  with an urltest group, refreshed daily; new `libexec/share_to_singbox.jq`
  converts vless/vmess/trojan/ss/hysteria2/tuic/anytls/socks/http links and
  rejects allowInsecure. Verified by round-tripping every sb-manager share link.
- `sb tools`: sing-box key generators, REALITY target check (TLS 1.3 and
  certificate coverage) and certificate hashes.
- Fix: the API dashboard HTTP client used `detour: direct`, which sing-box
  1.15 rejects.

## 0.1.0-alpha.93

- Telegram bot (same as xray-manager): `sb user tg NODE USER TG_ID` lets a
  bound user use `/me` (status, expiry) and `/link` (share link) in a private
  chat, scoped to their own users; expiry reminders 3 days ahead, once per
  expiry date, to the admin channel and the bound user; `/backup` sends a full
  backup to the admin chat when enabled with `sb notify bot backup on`.

## 0.1.0-alpha.92

- Subscriptions (same as xray-manager): without `?format` the client is
  detected from its User-Agent — Clash/mihomo/Stash/FlClash → mihomo,
  sing-box/SFA/Hiddify → sing-box, v2rayN/Shadowrocket/Happ/NekoBox → base64
  links; new `format=base64`; `Profile-Title` and `Profile-Update-Interval`
  headers; disabled or expired users receive a placeholder entry that says
  why. `sb subscription remark set '{name} | 剩 {days}天'` templates user
  subscription names (panel subscription menu 4).

## 0.1.0-alpha.91

- Same as xray-manager: `sb node clone SRC NEW` copies a node's settings with
  a free port and fresh credentials (REALITY keys included); templates and
  clone share one implementation.
- Users: `sb user add NODE --count N [--prefix P] [--days N]` adds a batch in
  one transaction; `sb user purge-depleted` deletes expired users;
  `sb user export|import` moves a user between nodes of the same protocol
  with unchanged credentials. Panel user menu 9–12. Per-user quotas, IP
  limits and delayed-start expiry need per-user counters that official
  sing-box does not provide (xray-manager has them).

## 0.1.0-alpha.90

- Share page (same as xray-manager): the link and QR come first; the sing-box
  and mihomo client files are exported independently, so a format that
  cannot express a node no longer hides the link or the others. mihomo
  configs are now offered for every protocol mihomo supports (not only Snell).
- Performance: port reservation checks use one jq pass; one shared jq socket
  model (`SBM_JQ_NODE_KINDS`) is used by validation, port checks and status.

## 0.1.0-alpha.89

- Panel onboarding (same as xray-manager): wizard steps accept Enter for the
  recommended choice instead of leaving the wizard; the VLESS wizard starts
  with a one-question REALITY + Vision path (port only, public IP detected).
  Verified: `2` → `7` → Enter → Enter yields a working node for sing-box and
  mihomo clients.

## 0.1.0-alpha.88

- Performance: rendered sing-box inbounds are cached by content (manager
  version, certificate directory, effective node, secret file bytes and, for
  Realm-enabled Hysteria2, the Realm settings and token) under
  `/run/sb-manager/render-cache`, pruned after a day; state validation runs as
  one jq pass. With 12 nodes a cached render drops from 9.0 s to 1.45 s and
  validation from 2.6 s to 0.6 s; output is byte-identical.
- Fix: `sb node add vless --security reality` and `sb node add shadowtls`
  no longer fail without `--handshake-server`; the target defaults to the SNI
  site (`www.apple.com` for ShadowTLS).

## 0.1.0-alpha.87

- Performance: `sb traffic status` (panel menu 16) formats the whole table in
  one jq pass instead of ~10 jq/awk calls per node (5.6 s → 0.7 s on a
  23-node test host, identical output); the panel node picker lists nodes
  with one jq call (2.6 s → 0.45 s).

## 0.1.0-alpha.86

- Fix: enabling Salamander/Gecko obfs on a Hysteria2 node created without
  obfs now generates the obfs password; previously the node rendered with an
  empty password. Verified with sing-box client traffic.
- Performance: `sb node list`, `sb status`, resource health checks and the
  panel header use one jq pass instead of several per node; listening
  sockets are sampled once per status call. Panel header refresh drops to
  ~0.03 s, status from 2.7 s to 1.5 s on the test host.

## 0.1.0-alpha.85

- Remove scratch files (`state.candidate.*`, `user-limits-before.*`,
  `xray-test.*`, `*.tmp.*`) older than ten minutes from the runtime directory
  whenever the manager lock is taken, so an operation aborted mid-way no
  longer leaves stale state copies behind.

## 0.1.0-alpha.84

- Add mihomo client export for every protocol (`export_mihomo_client_config`,
  panel client-config option 3, `mihomo` subscription format and bot `/sub`):
  the effective sing-box client outbound is converted by
  `libexec/singbox_to_mihomo.jq`, shared with xray-manager; fields mihomo cannot
  express are refused with a reason. Verified with mihomo v1.19.34 against
  sing-box VLESS TCP/gRPC Reality nodes.

## 0.1.0-alpha.83

- Split the project: sb-manager now runs every protocol, including VLESS, on
  sing-box only; Xray-core features move to the sibling project xray-manager.
  VLESS returns to sing-box (TCP + TLS/Reality, Vision flow, transports via
  `--sing-box-*-json`; share links follow the effective client outbound).
- Upgrading from alpha.72–82 migrates VLESS automatically: RAW + TLS/Reality
  nodes keep their UUID, Reality keys and links; nodes using Xray-only
  settings (XHTTP, mKCP, VLESS encryption, fallbacks, …) are disabled with
  their data kept and a migration note, and cannot be re-enabled here. The
  managed `sb-xray` service, its config and binary are stopped and removed
  before sing-box takes the ports back.
- Remove Xray-only features: `sb xray *`, Xray outbounds/WARP/balancers/routing,
  per-user traffic quotas, online-IP limits and usage statistics, and Xray/
  mihomo client exports. Per-user expiry, per-user subscriptions and the
  Telegram bot remain (bot commands without quota/IP/traffic).
- The shared-443 Reality website entry now runs on sing-box; a failed setup
  restores the previous sing-box config before restoring the website listener.

## 0.1.0-alpha.82

- Apply the shared log level and outbound IP strategy to Xray as well:
  `log.loglevel` follows the manager log level and the `direct` freedom
  outbound uses `UseIPv4v6`/`UseIPv6v4`/`UseIPv4` for prefer_ipv4/prefer_ipv6/
  ipv4_only. The panel entry is renamed to 核心通用设置.
- Reject `--sing-box-inbound-json` on VLESS nodes, which only Xray serves;
  `--sing-box-outbound-json` still customizes sing-box client exports.

## 0.1.0-alpha.81

- Speed up state changes with live per-user subscriptions (measured 32s → 5s
  with two subscriptions; unrelated changes skip rebuilding). VLESS client
  derivation, `xray -test` client checks and format conversions are cached
  content-addressed in a root-only runtime directory (pruned daily); user
  bundles record an input fingerprint and are rebuilt only when it changes,
  once per user per refresh, with their formats exported concurrently; the
  compatibility report covers only the subscribed user.

## 0.1.0-alpha.80

- Fix the VLESS and ShadowTLS wizards aborting with
  `SBM_RECOMMENDED_REALITY_SNI: unbound variable` after choosing Reality; the
  default (`www.apple.com`) is defined again in `lib/common.sh`.
- Fix VLESS creation from the panel failing with `--listen 目前仅用于
  socks/http/mixed`: `sb node add vless --listen IP` is now accepted, validated
  as an IP and written to the Xray inbound.

## 0.1.0-alpha.79

- sing-box no longer runs any VLESS node: `settings.vless_engine` accepts only
  `xray` or `disabled`, the sing-box VLESS inbound renderer and sing-box
  Reality key generation are removed, and Reality keys always come from
  official Xray (installed on demand).
- Legacy `sing-box` or missing engines migrate to Xray during state
  normalization; the next render installs Xray, restarts sing-box first to
  release ports, then starts Xray. UUIDs, Reality keys and share links are
  unchanged. `sb mux` with the sing-box backend still only forwards TCP by SNI.

## 0.1.0-alpha.78

- Fix `sb xray warp --register`: decode the WARP `client_id` as raw bytes for
  the WireGuard `reserved` field (jq `@base64d` decoded it as text and broke
  values above 127). Verified against Cloudflare registration with live
  traffic reporting `warp=on` through Xray's userspace WireGuard stack.

## 0.1.0-alpha.77

- Fix Xray configuration checks on Xray 26.x: the core now infers the config
  format from the file extension and rejected the manager's extensionless
  candidate files, so VLESS node changes and `sb xray config` failed. Checks
  now test a `config.json` copy in a private temporary directory (BusyBox
  `mktemp` has no `--suffix`), and client-profile failures report Xray's
  reason.

## 0.1.0-alpha.76

- Add Xray outbound management: native outbounds of any protocol with
  chaining (`--via` → `dialerProxy`), WARP via Xray WireGuard in userspace
  mode (`sb xray warp --register` or credential import), balancers with
  random/roundRobin/leastPing/leastLoad and automatic burstObservatory,
  routing rules by node, user, domain, IP, network or port, and a default
  exit. Outbound credentials stay in a 0600 secrets file.
- Add Xray per-inbound and per-outbound traffic counters (`sb xray traffic`).
- Add a Telegram command bot (`sb notify bot enable --admin ID`) restricted to
  the configured chat and an admin allowlist, with a fixed validated command
  set for status, users, traffic, enable/disable, renewal, quota, IP limit,
  usage reset and per-user subscriptions.
- Verify stats, online-IP and routing behaviour against Xray 26.11.9; warn
  that loopback-only listeners cannot enforce online-IP limits without
  PROXY protocol or trusted X-Forwarded-For.

## 0.1.0-alpha.75

- Add per-user live subscriptions (`sb subscription create ... --user
  NODE_ID:USER_ID`, panel user menu option 11). They contain only that user,
  send `Subscription-Userinfo` with upload, download, quota and expiry, stop
  serving node configuration while the user is suspended, and refresh usage on
  the periodic tick. Revocation removes the user bundle.

## 0.1.0-alpha.74

- Add per-user limits: `sb user limit` sets expiry for every multi-user
  protocol and, for VLESS on Xray, monthly or lifetime traffic quotas and
  online-IP limits. Counters come from a loopback-only Xray Stats API; users
  over a limit are suspended with credentials kept and resume automatically
  after renewal, cycle reset or the IP cooldown. Add `sb user stats`,
  `reset-usage`, `tick`, `sb xray api-port` and a panel user menu. Usage
  ledgers are included in backups.
- Add VLESS fallbacks (RAW + TLS only, with matching ALPN), inbound sniffing
  and server sockopt flags (`--fallback-dest`, `--fallbacks`, `--sniffing`,
  `--sniff-dest`, `--tcp-fast-open`, `--accept-proxy-protocol`,
  `--sockopt-json`).
- Replace the removed Xray `allowInsecure` with certificate pinning
  (`--pinned-cert-sha256`, `--verify-name`; URI `pcs`/`vcn`) and emit the
  current Reality client field `password`.
- Drop the nonstandard `support-x25519mlkem768` URI parameter.

## 0.1.0-alpha.73

- Treat the native Xray VLESS inbound/outbound objects as the single source of
  truth. `sb node set` and the panel edit transport (RAW, WebSocket, gRPC,
  HTTPUpgrade, XHTTP, mKCP, Hysteria, XDrive), security (none/TLS/Reality),
  client SNI/fingerprint/ALPN, Flow, UDP packet encoding and VLESS Encryption
  (X25519 or ML-KEM-768 via `xray vlessenc`) as one atomic candidate.
- Derive the client outbound from the effective server inbound and reject
  mismatched pairs (Reality public key/SNI/shortId, ML-DSA-65 verify, ECH,
  ALPN, paths, Host, XHTTP mode, Vision constraints) before installation; with
  Xray present the client outbound is also checked by `xray run -test`.
- Export the same profile as VLESS URI, sing-box, mihomo and full Xray client
  configurations. Formats that cannot express a field skip the node with a
  reason instead of emitting a lossy configuration; the dynamic subscription
  serves Xray and mihomo profiles plus a compatibility report.
- Detect UDP listeners for mKCP, Hysteria and XHTTP/H3 when checking ports.

## 0.1.0-alpha.72

- Run Xray and sing-box together: Xray owns VLESS, while sing-box owns all other
  protocols. Validate both candidate configurations before installing, preserve
  unchanged services, and restore both configurations and services on failure.
  New installs default to Xray; existing Xray services retain their engine,
  while legacy sing-box VLESS deployments migrate explicitly.
- Add `sb vps reality DOMAIN [nginx|caddy]` and the VPS panel entry to provision
  OpenList plus VLESS Vision Reality on TCP443, optionally initializing UFW and
  Fail2ban. Official Caddy needs no L4 plugin; both web servers use a loopback
  TLS target with HTTP/2 and TLS1.3. Detach restores direct website HTTPS.
- Keep existing node credentials when adopting VLESS/443, refresh subscriptions,
  reject conflicting listeners and unsafe website transformations, and protect
  the active website entry from ordinary node deletion or engine shutdown.
- Remove persistent automatic backups and obsolete binaries after successful
  operations. Bound file logs to one day with 1 MiB periodic truncation and
  the dedicated journal to 4 MiB. Preserve current data and active website
  configuration; incomplete recovery records expire after 23 hours.
- Stream official archives into their final filesystem, check disk and tmpfs
  memory headroom, omit unused Xray geo databases, use official musl OpenList
  builds on Alpine, and apply a configurable 128 MiB OpenList Go memory target.
- Fix Xray date version parsing, Vision flow and Reality target rendering,
  OpenList version parsing, engine-aware diagnostics and certificate reloads.

## 0.1.0-alpha.71

- Add OpenList installation, updates and Caddy/Nginx website setup to the CLI
  and VPS panel. Verify official release SHA-256 digests, initialize the admin
  before exposure, use a dedicated unprivileged account and loopback listener,
  and restore SQLite, configuration and the previous binary on failed updates.
- Add candidate validation, atomic website edits, graceful reload, HTTPS
  readiness and rollback. Refuse existing domains and conflicting listeners;
  prepare missing Nginx certificates with configured Cloudflare credentials
  and reload after renewal. Detaching removes only the managed site content.
- Include OpenList in status and daily log/cache maintenance, retaining two
  installation recovery records and the current/previous binaries. Ordinary
  installation does not change firewalls or migrate Reality's 443 listener.
- Add Xray management and optional VLESS JSON fields to the interactive panel;
  install Xray configuration atomically only after native validation succeeds.

## 0.1.0-alpha.69

- Clarify the Xray VLESS customisation flow and document 3x-ui style transport
  settings through the protected Xray JSON extension.

## 0.1.0-alpha.68

- Remove the automatic recommended-node creation path from the installer,
  command help, and interactive panel. Node creation now always goes through
  the explicit protocol and parameter flow.
- Add protected Xray inbound/outbound JSON extensions to node creation and
  editing. Xray VLESS can now carry 3x-ui style custom stream, TLS, Reality,
  WebSocket, gRPC, HTTPUpgrade, XHTTP, ALPN, fingerprint, destination,
  server-name, and short-ID settings while the manager retains ownership of
  credentials and listener identity.
- Normalize and validate the new Xray extension fields in state; no test
  scripts, test environments, or test procedures were added.

## 0.1.0-alpha.67

- Add optional Xray-core runtime support using the latest official
  XTLS/Xray-core Release assets. Provide install, update, status, config,
  enable, disable, and update-policy commands while keeping sing-box as the
  default service.
- Verify Xray archives with Release SHA-256 metadata or the official
  `SHA2-256=` checksum format, support amd64, arm64-v8a, and arm32-v7a assets,
  and retain independent version directories and service files.
- Render Xray configuration from the existing state for VMess, ordinary
  Shadowsocks, Trojan, VLESS, SOCKS, HTTP, and mixed nodes. Reject protocols
  and Shadowsocks 2022 methods that Xray cannot provide, preserving sing-box
  for those nodes. No test scripts, test environments, or test procedures were
  added or run.

## 0.1.0-alpha.66

- Add a zero-input recommended node: VLESS Reality with an auto-detected
  public address, a free port (443 first) and the default Reality camouflage
  site, followed directly by the share link and QR code. Available as
  `sb quick --auto [--address HOST] [--port N]`, installer `--quick`, main
  menu key `a`, and wizard option 12. No domain, certificate or Cloudflare
  token is required, and firewalls are not changed.
- Collapse protocol tuning prompts (Shadowsocks method, Hysteria2
  obfuscation/fingerprint/BBR/debug, TUIC congestion control, VLESS Reality
  SNI/handshake, NaiveProxy transport, ShadowTLS strictness, Snell version)
  into one "use recommended values" question; answering `n` keeps every
  existing advanced option. Recommended values follow the existing `sb node add`
  defaults; the ShadowTLS handshake target now defaults to the Reality site.
- Open the panel after `curl | bash` installations by reattaching the
  controlling terminal when available, otherwise print how to open it.
- No state migration, test assets or procedures; Debian/systemd and
  Alpine/OpenRC behavior is unchanged.

## 0.1.0-alpha.65

- Replace the long `sb help` wall with a grouped overview of commands and
  short descriptions. Add `sb help <命令>` and `sb <命令> --help` for the
  matching usage section (node help includes add parameters), plus
  `sb help all` for the complete reference. Help no longer requires root or
  state initialization.
- Suggest the closest command for mistyped commands (for example
  `sb stauts` → `sb status`) and append a `sb help <命令>` hint to
  subcommand usage errors. Exit codes, command behavior, Debian/systemd and
  Alpine/OpenRC support are unchanged; no state migration or test assets.

## 0.1.0-alpha.64

- Add explicit `sb caddy apt` enrollment for standard official stable APT
  Caddy on Debian/Ubuntu systemd. Route manual and daily updates through APT
  while preserving the existing updater schedule and Alpine/OpenRC behavior.
- Verify package origin and SHA256, validate the real website configuration
  with the candidate binary, refuse unrelated package changes, and restore
  the original package on installation or service failure. Unchanged packages
  do not restart Caddy; temporary downloads are removed and logs use the
  existing one-day retention policy.
- Keep standard-package enrollment separate from L4 management and reject
  implicit conversion back to website multiplexing. Document the optional
  state record; no test assets or procedures are introduced.

## 0.1.0-alpha.63

- Include managed Caddy in `sb update` and the existing daily updater, even
  when manager scripts are already current. Reuse the schedule and enable
  flag on systemd and OpenRC; leave unmanaged Caddy and core update policies
  unchanged. Check-only and dry-run operations query without writing state.
- Run the Caddy phase through the installed entry point after self-update.
  Attempt it even if the script stage fails, report partial failure, and keep
  the two stages' rollback boundaries separate.
- Download Caddy candidates before entering the switching transaction under
  the existing manager lock. Failed downloads and unchanged builds no longer
  create snapshots or trigger rollback restarts during daily maintenance.
- Update panel labels and operator documentation. No state migration, tests,
  fixtures, test environments, or test procedures are added.

## 0.1.0-alpha.62

- Shorten main and submenu labels by removing parenthetical descriptions.
  Keep menu numbers and actions unchanged, distinguish data-preserving and
  full removal directly in their labels, and simplify menu-choice prompts.
- Preserve existing input guidance, destructive-action confirmation, and
  Debian/systemd and Alpine/OpenRC behavior. No state migration or test
  assets are introduced.

## 0.1.0-alpha.61

- Refresh the official custom Caddy build on every explicit update, including
  when the core version is unchanged, so plugin and build dependency updates
  are not skipped. Keep the current service and rollback record when the
  downloaded program matches the running binary; refuse automatic downgrades.
- Clarify that update checks query only core releases and that retaining the
  official package does not start another Caddy service. Keep Debian/systemd
  and Alpine/OpenRC support without state migration or test assets.

## 0.1.0-alpha.60

- Make the managed Caddy program parent explicitly traversable by its service
  account, including hosts migrating from older custom binary layouts under a
  restrictive umask. Check candidate execution as the configured systemd
  service user before changing package integration or restarting websites.
- Preserve the existing rollback path and state schema; no test assets or
  procedures are added.

## 0.1.0-alpha.59

- Add explicit Caddy program enrollment, status, candidate-first updates and
  rollback. Integrate Debian/Ubuntu official packages through diversion and
  alternatives; retain separate binaries and OpenRC support on other systems.
- Download custom Caddy builds from the official HTTPS service by default,
  retaining module identities and validating architecture, version, integrity,
  website configuration and running service before completing a switch.
  Journal package/service changes for rollback; keep one prior program version.
- Keep local Caddy compilation opt-in through `--build-caddy`, isolate its Go
  caches, and remove successful build/download workspaces immediately.
- Add scheduled project cache/log maintenance, one-day retention windows,
  bounded file logs and an isolated journal namespace on systemd 245+. Preserve
  state, secrets, certificates, subscriptions, backups and recovery metadata;
  leave legacy shared journals and older systemd host policies intact.
- Add VPS panel entries and documentation for Caddy maintenance and retention.
  No test scripts, fixtures, environments or test procedures are introduced.

## 0.1.0-alpha.58

- Allow Caddy websites using file_server to enroll in shared TLS/443 without
  falsely rejecting an unchanged site: normalize only the candidate Caddyfile
  path that Caddy automatically adds to file_server.hide. Keep all other
  website settings and explicit hidden paths subject to exact comparison,
  native configuration validation and rollback.
- Document the verified Snell v6 limitation in official mihomo v1.19.33.
  No state or credential migration is required.

## 0.1.0-alpha.57

- Explain panel entries in Chinese, name Cloudflare functionality CF Tunnel,
  and group VPS initialization, UFW/Fail2ban, Nginx/Caddy shared 443 and network
  tuning under the VPS and website operations menu.
- Add a Sub-Store guide and first-use workflow covering installation, live
  local-node synchronization, SSH forwarding, collections and client export.
  Explain remote sources, refresh behavior and public-access requirements.
- Display native Surge Snell entries before ancillary exports in single-node
  and batch shares. Retain machine-readable files, skip redundant Snell URI/QR
  display, and explain the sing-box requirement for multi-user nodes. Preserve
  credentials and state schema without migration.
- Add read-only `sb vps systems` and a panel support matrix, distinguishing
  multi-distribution core management from Debian/Ubuntu and Alpine host
  initialization. Correct RPM-family probe/tc dependencies and Arch Sub-Store
  Python packages; retain BusyBox/OpenRC compatibility.
- Show shared public ports in node-creation firewall guidance. Ordinary node
  operations do not change host firewall rules.

## 0.1.0-alpha.56

- Keep sing-box installation and node management as the primary workflow; add
  explicit `sb vps init`, `sb vps status`, a panel entry, and installer
  `--init-vps` for new-host provisioning.
- Install Caddy, UFW and Fail2ban from distribution repositories on
  Debian/Ubuntu systemd and Alpine OpenRC. Open 22/TCP, 80/TCP and 443/TCP+UDP,
  always preserve the current SSH port, and retain existing firewall rules.
- Validate component configuration, protect before-images, and attempt to
  restore configuration/service state on failure. Reuse existing websites and
  SSH jails; reject conflicting web listeners and active firewalld. Reestablish
  Fail2ban actions after UFW applies its rules.
- Keep ordinary installation/upgrades and SSH authentication settings unchanged;
  provisioning is opt-in and cannot be combined with `--no-start`. No tests,
  fixtures, disposable environments or test procedures are added.

## 0.1.0-alpha.55

- Remember external edits when later synchronizing an owned directive in the
  same website file, so detach cannot silently restore over operator changes.
- Consume complete Caddy module listings when checking required modules to
  avoid SIGPIPE failures with large plugin sets under Bash pipefail.

## 0.1.0-alpha.54

- Add `sb mux setup` to detect an existing Nginx/Caddy HTTPS frontend, stage
  and validate website changes, preserve before-images, then activate shared
  TCP/443 with automatic node-route synchronization. Add `sb mux detach` and
  matching panel actions for guarded restoration.
- Keep Caddy's HTTP routes and TLS passthrough, adopting compatible alpha.53
  wrappers. Build a separate Caddy L4 binary when needed with pinned modules,
  Go checksum verification and preservation of existing module identities.
- Integrate Nginx stream with loopback website TLS listeners, PROXY protocol
  for real client addresses, and a local relay that strips that header for
  proxy nodes. Preserve UDP/443 and HTTP/80 listeners. Reject unsupported
  listener layouts, custom stream blocks and conflicting real-IP policies.
- Journal website files and service commands in state transactions, reload
  routes after node changes, and restore on failure. Refuse detach when an
  operator has modified managed files; retain host recovery metadata in
  backups and guard cross-host restore/uninstall.
- Support Debian/systemd and Alpine/OpenRC; Python and Caddy build tools are
  optional dependencies of website integration only. No firewall, SSH or
  Fail2ban rules are changed. No test assets or procedures are added.

## 0.1.0-alpha.53

- Add an explicit `caddy` TCP/SNI backend for sharing an existing website's
  public HTTPS port. Keep node listeners on loopback and export the frontend
  port in shares and subscriptions, without managing Caddy's lifecycle.
- Export TLS passthrough listener wrappers with `sb mux caddy`; unmatched
  connections continue to the existing HTTPS handler. Report the actual Caddy
  service in status and diagnostics on systemd/OpenRC.
- Preserve existing sing-box/Nginx defaults and schema-v2 states. Caddy requires
  a separately installed L4 module and explicit configuration/reload after
  route changes. No test assets, environments or procedures are added.

## 0.1.0-alpha.52

- Prepare Cloudflare DNS-only A/AAAA records and DNS-01 certificates when
  adding an enabled TLS node without a usable certificate, in both the wizard
  and CLI. Reuse the saved API Token, email, matching records and certificates.
- Resolve the domain's active zone, compare normalized IPv6 addresses, and
  refuse conflicting addresses, proxied records and CNAME/NS delegations.
- Journal DNS creations before API writes and clean up only unchanged records
  created by the failed transaction; report remote cleanup failures separately
  while preserving local rollback. Keep certificate-only issuance available.
- Retain Debian/systemd and Alpine/BusyBox/OpenRC support without new runtime
  dependencies. No schema migration or test assets/procedures are added.

## 0.1.0-alpha.51

- Allow every supported protocol to carry validated sing-box inbound and
  outbound extension JSON, including fields added by newer core releases.
- Preserve those extensions in node templates and apply them to generated
  server and client configurations while keeping manager-owned credentials and
  listener identity authoritative.
- Raise the verified offline fallback core to sing-box 1.14.4.

## 0.1.0-alpha.50

- Reduce the README to a two-step guide: install first, then use `sb`.
- Use one installation entry point for supported systemd/OpenRC systems and
  keep Alpine's bootstrap dependency note concise.
- Move detailed protocol and operational guidance to the existing `docs/`
  pages. Static checks only; no test scripts or procedures were added.

## 0.1.0-alpha.49

- Remove the legacy Snell credential-recovery compatibility path at the
  operator's request; old nodes can be rebuilt manually.
- Keep the current migration rule explicit: newly created Snell nodes carry
  revision 1 credentials, and routine manager updates do not rotate them.
- Document that only an explicit credential rotation invalidates a current
  Snell client. Static checks only; no test scripts or procedures were added.

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
