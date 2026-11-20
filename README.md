# sb-manager

`sb-manager` 以 sing-box 一键安装和多协议节点管理为主，支持 systemd 和 OpenRC，并提供可选的新 VPS 基础初始化。所有协议（含 VLESS）只由 sing-box 运行；需要 Xray-core 专属能力（XHTTP、mKCP、VLESS 加密、用户级流量配额等）时请使用姊妹项目 xray-manager，两者可以装在同一台服务器上。安装后运行 `sb`，按面板提示添加节点、申请证书和导入客户端。

当前版本：`0.1.0-alpha.93`

## 第一步：安装

所有支持的 Linux 系统使用同一个安装入口。请用 root 执行；非 root 用户在命令前加 `sudo`：

```bash
curl -fsSL https://github.com/ridd1e1337/sb-manager/raw/refs/heads/main/install.sh | bash
```

安装器会自动识别 systemd/OpenRC，安装管理器和最新 sing-box，并默认开启管理脚本与受管 Caddy 的每日自动更新。

Alpine 的最小镜像通常没有 Bash、curl 和 tar，先执行一次：

```bash
apk add --no-cache bash curl tar ca-certificates
```

然后仍使用上面的安装命令。支持 Debian、Ubuntu、Alpine、Rocky、Alma、Fedora、Arch 和 openSUSE；系统必须实际运行 systemd 或 OpenRC。安装完成后自动打开面板（`curl | bash` 也可以）；不需要时追加 `--no-menu`，固定核心版本可追加 `--core-version VERSION`。

新 VPS 可同时安装并启用 **Caddy、UFW、Fail2ban**（Debian/Ubuntu systemd、Alpine OpenRC）：

```bash
curl -fsSL https://github.com/ridd1e1337/sb-manager/raw/refs/heads/main/install.sh | bash -s -- --init-vps
```

UFW 自动放行 **22/TCP、80/TCP、443/TCP、443/UDP**，并保护检测到的当前 SSH 端口；新启用时默认拒绝其他入站、允许出站，已有规则保留。安装过本脚本也可运行 `sb vps init`，或选择“15. VPS 与网站运维 → 新 VPS 一键初始化”。普通安装和更新不会触发初始化。详情见[新 VPS 初始化](docs/OPERATIONAL_FEATURES.md#新-vps-初始化alpha56)。

各功能的系统范围可用 `sb vps systems` 查看；完整列表见[系统支持说明](docs/OPERATIONAL_FEATURES.md#系统支持说明)。

## 第二步：使用

打开交互面板：

```bash
sb
```

常用流程：

1. 选择“添加节点”，选择协议；地址、端口都有推荐值，直接回车即可。各协议的进阶选项合并成一个问题“其余选项使用推荐值？”，回车跳过，输入 `n` 再逐项设置。
2. 需要 TLS 的协议直接输入 Cloudflare 托管的域名；没有可用证书时，自动添加指向本机公网 IP 的 DNS 记录（关闭橙云），再申请证书。首次填写 API Token 和邮箱，之后自动复用。
3. 创建完成后复制分享链接、二维码或 sing-box 配置，导入客户端。Snell 会把 Surge 原生配置放在最上面，可直接复制到 Surge 的 `[Proxy]` 段。

面板按节点管理和维护功能分组，菜单使用简短名称：Cloudflare 隧道在 **7. CF Tunnel**；初始化、防火墙、Fail2ban、Nginx/Caddy 共用 443 和网络调优集中在 **15. VPS 与网站运维**。

**20. Sub-Store 订阅管理**用于合并多台 VPS/多个来源的节点，按客户端格式导出订阅，也能筛选、改名。单个节点可直接用分享内容；需要管理多份订阅时，进入 Sub-Store 后选 **11. 首次设置**完成安装和本机节点接入，选 **12. 使用指南**查看网页访问、组合与客户端导入方法。详见[Sub-Store 使用入门](docs/OPERATIONAL_FEATURES.md#sub-store-使用入门)。

Token 需要目标区域的「Zone:Read」和「DNS:Edit」权限。已有可用证书直接复用；已有 DNS 指向其他地址或开启橙云时会提示处理，建议为节点使用独立子域名。命令行添加 TLS 节点也支持自动准备 DNS 和证书，详见[域名与证书自动准备](docs/OPERATIONAL_FEATURES.md#节点域名与证书自动准备alpha52)。

常用命令：

```bash
sb status                         # 查看服务和节点
sb node list                     # 列出节点
sb share NODE_ID                 # 显示节点分享内容
sb node show NODE_ID             # 查看节点详情
sb update                        # 更新管理脚本与受管 Caddy
sb update auto status            # 查看每日自动更新状态
sb help                          # 按功能分组的命令总览
sb help node                     # 查看某个命令的完整用法，也可用 sb node --help
```

输错命令时会提示最接近的写法，例如 `sb stauts` 会提示 `sb status`。

管理器安装和 `sb core update` 默认跟随 sing-box 最新稳定 Release。协议添加还支持把当前核心的新增字段直接写入节点：

```bash
sb node add trojan --id edge --domain edge.example.com --address edge.example.com \
  --sing-box-inbound-json '{"tcp_fast_open":true,"tls":{"alpn":["h2","http/1.1"]}}' \
  --sing-box-outbound-json '{"tcp_multi_path":true,"connect_timeout":"10s"}'
```

参数也可以使用 `@/path/to/fields.json`。扩展会同时进入服务端 inbound 和 sing-box 客户端 outbound，实际字段由已安装核心校验；管理器继续接管协议类型、标签、地址、端口、用户和凭据。ShadowTLS 等复合协议可在 JSON 中使用 `by_tag` 按生成的 tag 指定扩展。修改已有节点使用相同参数：`sb node set NODE_ID --sing-box-inbound-json @FILE`。

VLESS 由 sing-box 运行，支持 TCP + TLS/Reality 与 Vision flow。WebSocket、gRPC、
HTTPUpgrade 等传输通过 sing-box 扩展同时写入服务端和客户端，分享链接按实际客户端
配置生成：

```bash
sb node add vless --id g1 --address edge.example.com --port 8443 --security reality \
  --domain www.apple.com --handshake-server www.apple.com --handshake-port 443 --flow '' \
  --sing-box-inbound-json '{"transport":{"type":"grpc","service_name":"g1"}}' \
  --sing-box-outbound-json '{"transport":{"type":"grpc","service_name":"g1"}}'
```

从 alpha.72～82 升级时，原先由 Xray 运行的 VLESS 节点自动交回 sing-box：TCP +
TLS/Reality 节点的 UUID、Reality 密钥和分享链接不变；使用 XHTTP、mKCP、VLESS 加密、
回落等 Xray 专属配置的节点会被停用并保留数据（`sb node show` 可见迁移说明），可在
xray-manager 中重建。旧版托管的 sb-xray 服务会被停止并移除。

### 用户到期

```bash
sb user add edge alice
sb user limit edge alice --days 30        # 或 --expire-at 2027-01-01T00:00:00Z / --no-expiry
sb user stats [edge] [--json]
```

到期时间适用于所有多用户协议：到期后用户被暂停但保留凭据，续期后自动恢复。检查随
流量周期任务运行（systemd 5 分钟、OpenRC 15 分钟），也可执行 `sb user tick`。面板
`3 → 节点 → 12` 可管理用户。用户级流量配额与在线 IP 上限需要 Xray 统计，属于
xray-manager；sb-manager 提供节点级配额与限速（`sb traffic set`）。

`sb subscription create never mixed --user edge:alice`（或 `mihomo`）生成只含该用户的动态订阅，
响应带 `Subscription-Userinfo`（含到期时间），用户暂停后订阅不再返回节点配置。

### Telegram 命令机器人

先 `sb notify configure telegram ...`，再 `sb notify bot enable --admin 你的TG用户ID`。
机器人只响应已配置 chat 中白名单用户的固定命令：`/status /nodes /users
/enable /disable /renew /sub`，参数逐项校验后调用 `sb`。

### Web 面板与多服务器

Web 面板和多服务器 Agent 由配套项目
[sb-manager-web](https://github.com/ridd1e1337/sb-manager-web) 提供，只通过 `sb` CLI 操作本项目。

新建 Snell 节点的 PSK 和 userkey 会持续保留，普通脚本更新不会使客户端突然失效。只有执行 `sb node rotate`、`sb user rotate` 或把单用户节点改成多用户时，才需要重新导入客户端。单用户 Snell 的单节点和批量分享都优先显示 Surge 原生配置；v5 使用兼容的 `version=4`，v6 需要支持该版本的 Surge。多用户模式使用 sing-box 配置。

多个 TLS 节点可以使用内置 TCP/SNI 复用：

```bash
sb mux auto all --port 443 --backend sing-box
```

如果 443 已由 Nginx/Caddy 网站占用，运行一次：

```bash
sb mux setup
```

自动识别网站程序、备份配置、补齐所需模块并接入 SNI 分流。此后添加、删除、启停 TCP/TLS 节点会自动同步，分享链接使用公网 443，后端只监听本机。也可在“15. VPS 与网站运维 → 网站与节点共用 443 → 一键接入现有 Nginx/Caddy 网站”操作；恢复入口用 `sb mux detach`。UFW、SSH 和 Fail2ban 设置保持不变。支持范围和迁移边界见[网站一键接入](docs/OPERATIONAL_FEATURES.md#nginxcaddy-网站一键接入alpha54)。

Caddy 默认从官方构建接口下载带 L4 的程序，无需在 VPS 编译；Debian/Ubuntu 保留官方源，并使用 diversion/alternatives 管理定制程序。已有网站接入可运行 `sb caddy manage` 迁移到这一维护方式。菜单 15 提供版本查询、升级与回滚：

```bash
sb caddy status
sb update --check
sb update
sb caddy rollback
```

`sb update` 先处理管理脚本，再更新已接入管理的 Caddy；脚本没有新版本时仍会继续。现有每日任务执行相同流程，沿用原来的开关和服务器本地时间，无需另设任务。Caddy 升级先校验模块和网站配置，再切换并确认服务；失败恢复旧版。即使主版本未变，也会重新获取官方插件构建；程序摘要一致时不重启，下载失败不触发服务回滚。`--check` 只查询脚本及 Caddy 主程序版本，不下载插件构建。sing-box 和 cloudflared 继续使用各自的更新策略。详情见 [Caddy 程序维护](docs/OPERATIONAL_FEATURES.md#caddy-程序维护alpha59)。

面板 `15 → 9` 提供 OpenList 网站安装、更新和 Caddy/Nginx 配置，也可执行：

```bash
sb openlist setup files.example.com caddy
# 使用 Nginx 时选择：
sb openlist setup files.example.com nginx
```

网站程序需已安装并运行。首次配置会安装 OpenList 官方最新版，并显式建立管理员；
OpenList 使用独立低权限用户，默认只监听 `127.0.0.1:5244`。
Caddy 通过域名解析申请 HTTPS；Nginx 复用本项目证书，没有证书时使用已配置的
Cloudflare 凭据准备 DNS 并申请证书。初始管理员信息保存在
`/etc/sb-manager/secrets/openlist-admin.txt`，数据保存在 `/var/lib/sb-openlist`。
站点配置先保存备份，再校验、原子安装和平滑重载，失败尝试恢复；已有域名拒绝覆盖。
`sb openlist detach DOMAIN` 移除本项目站点入口，保留 OpenList 数据。
需要 OpenList 与 VLESS Vision Reality 共用 TCP/443，使用面板 `15 → 10`，或：

```bash
# 新 VPS：同时安装网站、OpenList、UFW 和 Fail2ban
sb vps reality files.example.com nginx
# 使用官方标准 Caddy 时，最后一项换成 caddy
# 已有基础环境，仅配置网站与节点：
sb reality setup files.example.com caddy
```

sing-box 的 VLESS Reality 入站监听公网 TCP/443，Reality 握手和普通 HTTPS 访问转给本机 TLS 网站，再由网站反代 OpenList。
Nginx 和 Caddy 均支持，Caddy 无需 L4 插件和本地编译。Nginx 需要本项目现有证书或
Cloudflare 凭据；Caddy 可通过 HTTP80 申请证书，有 Cloudflare 凭据时会准备 DNS。
仅在显式 VPS 初始化入口配置 UFW：新主机放行 22/TCP、80/TCP、443/TCP、443/UDP，
保留实际 SSH 端口及已有规则。只允许这几个公网端口时，其他协议的高位端口需自行决定
是否开放。`sb reality detach` 恢复网站直接使用 443，并停用该 Reality 节点。

小 VPS 默认推荐 Nginx。程序不会长期保留自动备份或旧版核心；下载包及时删除，
安装前检查实际可用空间。官方 OpenList v4.2.10 程序约 162 MiB，没有官方 lite 包；
1 GiB 总磁盘不等于根分区有 1 GiB。OpenList 适合挂载外部网盘，避免将小根分区当作
文件存储。复杂网站配置会拒绝自动迁移，详细边界见[操作说明](docs/OPERATIONAL_FEATURES.md)。

节点使用独立端口时，Caddy 可直接使用官方 stable APT 包。Debian/Ubuntu systemd 上执行 `sb caddy apt`，将现有标准包接入 `sb update` 和每日任务；仍可正常使用 `apt update && apt upgrade`。该命令只登记已恢复的标准包，不自动拆除 L4、修改网站或开放端口。更新会核对官方源与 SHA256、用候选程序校验网站配置，再通过 APT 安装；失败尝试恢复原包。已登记的标准包不会自动装回 L4。

安装后自动维护项目缓存与日志，最长约一天，并限制日志容量；成功下载和编译的临时目录立即删除。查看策略用 `sb maintenance status`，手动清理用 `sb maintenance run`。默认只保留当前程序；自动备份在操作完成后删除，恢复失败的临时资料最多保留 23 小时。证书、凭据、规则、手动备份和活动网站配置保留。迁移前的共享系统日志仍按宿主机策略管理。

更多协议参数、安全边界、证书、Sub-Store、备份和高级功能见：

- [协议安全边界](docs/PROTOCOL_SECURITY.md)
- [可选运维功能](docs/OPERATIONAL_FEATURES.md)
- [状态文件说明](docs/STATE_SCHEMA.md)
