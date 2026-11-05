# 可选运维功能（0.1.0-alpha.32 起）

参考 vps-tcp-tune 的测速、端口计费、代理入口、Tunnel 与 Sub-Store 管理思路，
按 sb-manager 的状态、凭据和事务模型实现。全部按需启用；默认安装不增加
Node.js、Python、iperf3 或 tc 依赖。兼容 Debian/systemd 和 Alpine/OpenRC。

从 alpha.42 起，菜单和选择列表用 Enter / `0` 逐级返回；结果页 Enter 直接回到
主菜单，输入 `r` 留在当前菜单继续操作。主菜单 Enter 保持等待，输入 `0` / `q`
或空输入时按 `Ctrl-D` 退出；普通配置输入中 `q` 取消。编辑字段时 Enter 保留
显示值；组成员支持逗号分隔的编号或 ID，重复成员自动去重，输入 `k` 保留已有
成员。网卡会标出已配置网卡或默认路由网卡供选择。测速对比第二次仅列出同条件
记录。CF Tunnel 路由路径可输入 `-` 清空，Sub-Store 升级保留现有端口并显示当前组件版本。

认证代理向导按监听地址建议客户端地址：本机监听保留 loopback，公网监听
使用检测到的服务器地址，无法取得时要求填写；端口建议会避开已占用端口。

从 alpha.57 起，主菜单按“功能名＋用途”展示；7 为 CF Tunnel（Cloudflare
隧道），14 为 sing-box 设置，15 为 VPS 与网站运维，20 为 Sub-Store 订阅管理。
VPS 分类集中提供初始化、基础环境状态、UFW/Fail2ban、Nginx/Caddy 共用 443、
BBR/TCP/QUIC 网络调优、测速和系统支持说明。旧主菜单 21 仍可进入该分类。

## 系统支持说明

`sb vps systems` 显示当前内核架构、包管理器分支、服务管理器和功能范围，
也可在“15. VPS 与网站运维 → 支持的 Linux 系统与当前环境”查看。
此命令只显示信息，不需要 root，也不会创建状态、安装软件或更改服务。

| 发行版 | 包管理器 | 常用服务管理器 | sing-box 安装与节点管理 | 新 VPS 整体初始化 |
| --- | --- | --- | --- | --- |
| Debian / Ubuntu | apt | systemd | 支持 | 支持 |
| Alpine | apk | OpenRC | 支持 | 支持，需 community 源 |
| Fedora / Rocky / Alma | dnf / yum | systemd | 支持 | 暂不提供 |
| Arch | pacman | systemd | 支持 | 暂不提供 |
| openSUSE | zypper | systemd | 支持 | 暂不提供 |

系统必须实际运行 systemd 或 OpenRC，并有与架构匹配的 sing-box Release。
可选组件使用已配置的发行版软件源；不会为了安装组件自动添加第三方源。
网站共用 443 还要求兼容的 Nginx/Caddy 配置：Nginx stream 模块目前只在
Debian/Ubuntu、Alpine 自动补装，其他系统需要先安装匹配的模块。
内核 BBR、nftables 流量计数、tc 限速等取决于内核和权限，普通容器不视为完整 VPS。

可选依赖按发行版映射：Fedora/Rocky/Alma 的 `ss` 使用 `iproute`、`tc` 使用
`iproute-tc`；Arch 的 Sub-Store 使用 `nodejs` 和 `python`；Alpine 继续按需
使用拆分的 `iproute2-ss`、`iproute2-tc`，保留 BusyBox/OpenRC 兼容。

## 新 VPS 初始化（alpha.56）

项目的主功能仍是 sing-box 安装与节点管理。基础环境初始化是独立的显式操作：

```bash
sb vps init
sb vps status
```

也可在首次安装时传入 `--init-vps`，或选择“15. VPS 与网站运维 → 新 VPS 一键初始化”。
支持 Debian/Ubuntu + systemd、Alpine + OpenRC，使用发行版已配置的签名软件源
安装 Caddy、UFW、Fail2ban。Alpine 需要可用的 community 软件源；缺少包时会
报错，不自动添加第三方源。新 VPS 的基础初始化与网站 443 共存接入是两个功能：
这里沿用 Caddy 包的默认配置或创建 HTTP 欢迎页，域名网站配置好后可使用
`sb mux setup` 接入节点分流。

UFW 会允许 22/TCP、80/TCP、443/TCP 和 443/UDP，后者用于 HTTP/3 或 QUIC。
同时探测 sshd 配置、监听套接字和当前 `SSH_CONNECTION`，保留实际 SSH 端口；
显式的 `SBM_SSH_PORTS` 也不会排除当前连接端口。新启用 UFW 时设为默认拒绝
入站、允许出站。不会 reset 或清空已有规则，也不会按节点列表额外开放端口；
因此已有规则和非标准 SSH 端口可能使放行范围多于这三个端口。IPv6 沿用
发行版 UFW 的配置，若管理员已关闭 UFW IPv6 支持，需另行处理 IPv6 防护。
云厂商安全组仍由管理员管理。

已有正常工作的 Caddy 和 Fail2ban SSH jail 会复用；UFW 应用后会重启 Fail2ban
以重新建立封禁规则。没有 SSH jail 时使用 600 秒内失败 5 次、封禁 3600 秒，
并将本机和当前 SSH 客户端 IP 加入忽略列表。Debian 按需补齐 journal Python
依赖；Alpine 按需启用系统日志服务以供 Fail2ban 读取。SSH 登录配置、密钥和
认证方式保持原样，初始化不会自动关闭密码登录或改 SSH 端口。

操作由管理器锁保护。Caddy/Fail2ban 配置经过原生程序校验，Fail2ban 使用
候选目录校验后安装；UFW 配置和服务状态保存到
`/var/lib/sb-manager/vps-init/<时间>/`。失败时尝试恢复本次修改的规则、配置
和服务状态，已安装的包保留，修正问题后可重试。成功记录位于同目录的
`last.json`，状态命令读取实时服务状态。备份和日志仅供 root 访问。

80/443 已由其他程序占用，或 firewalld 正在运行时，初始化会停止，避免改动
现有网站入口。该入口面向新 VPS，不适合直接替换已有 Nginx 环境。
`--init-vps` 与 `--no-start` 不能合用；VPS 初始化失败不会撤销已完成的
sing-box 安装。普通安装、日常升级和节点操作不会自动触发这套初始化。

## 节点域名与证书自动准备（alpha.52）

添加 AnyTLS、Hysteria2、Trojan、TUIC、Naive 或 VLESS TLS 节点时，输入
Cloudflare 托管的域名即可。已有有效且私钥匹配的证书会直接复用；缺少可用
证书时，管理器查询域名所属的有效区域，探测本机公网 IPv4/IPv6，为探测到
的地址创建 A/AAAA 记录（`proxied:false`、自动 TTL），然后用 acme.sh 的
Cloudflare DNS-01 签发并部署证书。DNS-01 通过 TXT 记录验证域名，不要求
开放 80 端口，也不依赖新 A/AAAA 记录的缓存刷新；客户端连接仍需等待 DNS 生效。

首次在向导填写 Cloudflare API Token 和 ACME 邮箱，之后复用保存的凭据。
Token 需包含目标区域的 `Zone:Read` 和 `DNS:Edit`；Zone ID 可留空自动查询。
已配置 Zone ID 时，域名必须属于该区域。命令行可先保存凭据，再创建节点：

```bash
sb cert setup-cloudflare
sb node add anytls --id edge --domain edge.example.com
```

同域名的已有 A/AAAA 只有在指向探测到的本机 IP 且关闭橙云时才复用。
遇到其他地址、橙云、CNAME 或 NS 记录时停止操作，请为节点使用独立子域名，
或在 Cloudflare 控制台先修正记录。不会自动覆盖网站或 Tunnel 的 DNS。
已有证书复用时不改 DNS；`--disabled` 创建停用节点时不准备 DNS/证书；
Reality、ShadowTLS 的握手域名和 VMess Tunnel 域名不走此流程。

探测不到公网地址时可通过 `SBM_PUBLIC_IPV4` / `SBM_PUBLIC_IPV6` 显式提供地址；
`SBM_DISABLE_IPV6_DETECTION=1` 可只准备 IPv4，但若已有无法核对的 AAAA 则仍会
拒绝继续。独立的 `sb cert issue DOMAIN` 和证书菜单只签发证书，保留手工
DNS、转发入口和其他部署方式。

DNS 请求与证书申请由管理器锁保护。本次新建记录带独立标记，先写事务日志，
再调用 API；签发或后续本地事务失败时只尝试删除本次创建且未被改动的记录。
清理失败会显示日志路径，需在 Cloudflare 控制台核对。向导先完成域名与证书
准备，再继续填写节点参数；准备成功后取消创建节点会保留 DNS 和证书供复用。
普通节点删除和本地备份恢复不会删除已成功创建的 Cloudflare 记录。

## Nginx/Caddy 网站一键接入（alpha.54）

网站通过系统的 `nginx` 或 `caddy` 服务监听 TCP/443 时，执行 `sb mux setup`
即可接入。也可指定 `--server nginx|caddy`、`--config /实际配置路径` 和
`--binary /实际程序路径`。先接入网站，再添加节点，无需先开放临时端口：

```bash
sb mux setup
sb node add anytls --id any-main --domain node.example.com
```

面板入口：“15. VPS 与网站运维 → 网站与节点共用 443 → 一键接入现有 Nginx/Caddy
网站并自动同步”。自动接入后，全部启用的 AnyTLS、Trojan、VLESS TLS/Reality、
Naive TCP、ShadowTLS 都按唯一 SNI 分流；添加、删除、启停、修改域名会自动更新
网站入口。节点只监听本机，分享与订阅使用公网 443，UFW 无需额外放行。
节点必须使用与网站不同的域名，且不能开启隐藏 SNI 的 ECH。SS、Snell、
VMess Tunnel 和 QUIC 协议不在该 TCP/SNI 接入范围内。

Caddy 沿用 HTTP 网站配置并增加 L4 listener wrapper。缺少 L4 时会在独立路径
编译程序，保留原程序，固定 `xcaddy`/`caddy-l4` 源码版本并通过 Go 校验数据库
验证模块；缺少合适 Go 时，从官方元数据取 SHA-256 校验下载。已有模块保留，
无可复现版本的本地模块拒绝自动重建。低于 2.11.7 的 Caddy 会升级到构建基线
2.11.8。首次构建可能耗时数分钟，需要约 1.8 GB 可用磁盘；不在基础安装时
安装这些工具。systemd 用独立 drop-in，Alpine OpenRC 保留服务脚本并更新
`command`，使启动和重载都使用带 L4 的程序。自定义 Caddy 的安全更新需维护
带相同模块的版本；发行版软件包更新不会更新这个独立程序。

Nginx 使用现有进程的 Stream 模块：公网 TCP/443 按 SNI 分流，网站 TLS
监听移到本机端口。Stream 向网站发送 PROXY 协议以保留真实客户端地址；
节点经过另一条本机 Stream 监听剥离此头，再收到原始 TLS 数据。
HTTP/80、UDP/443、证书和业务 upstream 保留。支持标准 wildcard 443 ssl
监听、include 及多站点；已有自定义 Stream、real-IP 信任链、指定公网 IP
绑定、混合 TCP 端口或依赖 `$server_port` 的网站会停止自动接入。容器内的
Nginx/Caddy、自定义服务名和无法识别的配置布局也不自动改写。

Python 只在接入时按需安装，用于按语法编辑配置及记录恢复信息。候选网站配置
和 sing-box 配置均通过实际程序校验后才安装。首次切换服务可能短暂中断连接，
后续路由变化使用重载。应用失败时按操作快照恢复网站配置、服务命令与节点状态；
外部修改过的文件不会被显式恢复命令覆盖。

```bash
sb mux detach
```

该命令恢复接入前的网站配置和复用方式；若原先没有分流，节点恢复独立端口。
若接入前已有 alpha.53 Caddy 分流，则保留它原来的手工配置。相关原节点被删除
或改了域名时，恢复可能因旧路由不再适用而被拒绝，需先处理旧路由。
网站配置被人工修改后，恢复会要求先合并修改；不会静默覆盖后来的网站内容。
恢复信息保存在 `/var/lib/sb-manager/website-mux/`，每次操作的 before-image
保存在状态快照内。完整备份包含这些信息供人工恢复，同一接入配置可恢复节点；
不会把其他主机的网站路径和服务命令直接应用到本机。卸载前也会先恢复网站入口。

仅开放 22/80/443 并不能让所有协议共用 443：TCP 与 UDP 是不同监听。
Caddy/Nginx HTTP/3 占用 UDP/443 时，Hysteria2/TUIC 不能再直接绑定同一 UDP 端口。

## 与现有 Caddy 网站共享 443（alpha.53，手工接入）

Caddy 已监听 443 时，先为 AnyTLS 等 TLS 节点选一个空闲端口，再显式选择
`caddy` 方式。Caddy 需要编译 `github.com/mholt/caddy-l4`；普通 HTTP
`reverse_proxy` 无法透传 AnyTLS。管理器不会安装模块或改写 Caddy 网站配置。

```bash
sb node add anytls --id any-main --domain node.example.com --port 24443
sb mux auto any-main --port 443 --backend caddy
sb mux caddy
```

启用后，节点改为只监听分配的 `127.0.0.1:后端端口`，分享链接和订阅使用
`node.example.com:443`。将最后一条命令输出保存为 Caddy 片段，在全局选项
的 `servers :443` 中 `import`；若已有 `listener_wrappers`，需合并，保持
`layer4` 在 `tls` 前。校验并重载 Caddy 后，匹配节点 SNI 的原始 TLS 连接
转入后端，其余连接继续由现有网站处理。无需开放后端端口或修改 UFW。

路由增删或后端端口变化后，需要重新导出并重载 Caddy。停用管理器复用不会
移除 Caddy 的片段，需同步移除对应分流。Caddy 网站与节点应使用不同域名，
此模式依靠可见 SNI；节点不要启用隐藏 SNI 的 ECH。网站的 UDP/443 HTTP/3
仍由 Caddy 占用，不能同时给 Hysteria2/TUIC 直接使用。

使用自定义 Caddy 二进制时，应将 systemd/OpenRC 的启动与重载命令都指向
该二进制，并保留原程序、配置与服务定义以便回滚。状态页检查 `caddy`
服务和端口，不能代替对外部 Caddy 路由配置的核对。

## 吞吐测速与对比

目标需要运行自己的 iperf3 服务。管理器只启动客户端，默认测试 10 秒、单连接，
最多 30 秒、16 个连接；测速会实际传输数据。

```bash
sb deps install benchmark
sb network speed 192.0.2.10 --port 5201 --seconds 10 --streams 1 --direction down --json
sb network speed 192.0.2.10 --port 5201 --seconds 10 --streams 4 --direction up
sb network history
sb network compare BEFORE_ID AFTER_ID --json
```

记录保存在 `/var/lib/sb-manager/network-tests/`（目录 0700，文件 0600），包含
iperf3 JSON、接收吞吐、重传统计和 TCP 调优快照。只比较相同目标、端口、时长、
连接数和方向的结果。线路和对端负载会影响结果，建议多次测试。写入默认历史
目录需要 root；原有 `network ping` 仍可由普通用户运行。

面板：“诊断与修复 → 吞吐测速与前后对比”。

## SOCKS5、HTTP 和 mixed 入口

```bash
sb node add socks --id socks-local --port 1080
sb node add http --id http-local --port 8080
sb node add mixed --id mixed-main --listen 0.0.0.0 --address 192.0.2.20 --port 1081
sb share mixed-main
sb user add mixed-main second-user
```

默认监听 `127.0.0.1`，也可选 `::1`、`0.0.0.0`、`::`。每个用户自动生成
独立用户名/密码，复用节点启停、凭据轮换、模板、导出和流量策略。mixed 同时
接受 HTTP 和 SOCKS5，默认分享为 SOCKS5 链接。普通 SOCKS5/HTTP 不加密，
跨公网访问应结合受信任的加密通道。

SOCKS5/mixed 的 UDP relay 使用动态端口，不能由当前端口账本完整计费；启用
节点或共享流量策略时，管理器拒绝这些节点的 UDP 转发，并导出 TCP-only
outbound，避免绕过配额。未启用流量策略时保留核心原有 UDP 能力。

面板：“添加协议节点 → SOCKS5 / HTTP / mixed 认证代理”。

## 节点到期与续期

```bash
sb node expiry mixed-main --days 30
sb node expiry mixed-main --at 2027-01-01T00:00:00Z
sb node expiry mixed-main
sb node expiry mixed-main --clear
```

`--days` 从原到期日与当前时间中较晚的时刻延长；`--at` 使用 UTC。到期任务
停用节点并保留配置、凭据与流量记录。续期或清除期限会恢复因到期而停用的
节点，原本手动停用的节点保持停用；普通“启用”不能绕过到期策略。

复用流量维护任务：systemd 每 5 分钟、OpenRC periodic 每 15 分钟检查，停用
可能有一个检查周期的延迟；OpenRC 需要运行 cron。配置通知后，在到期前 3 天
和停用后分别发送去重通知。`sb traffic tick` 可主动执行检查。

面板：“管理现有节点 → 设置/延长节点有效期”。

## 多节点共享配额

```bash
sb traffic group set family --nodes snell-main,hy2-main,mixed-main --quota 500G \
  --reset-day 1 --quota-mode total
sb traffic group status --json
sb traffic group reset family
sb traffic group remove family
```

使用共享 nftables quota 和独立组用量账本，支持双向合计或仅下行；与单节点
配额可同时生效。每个节点只能属于一个组。创建组启用成员流量统计，修改成员
不清空组累计用量。删除节点或取消其流量统计前需要先移出组。移除组保留用量
记录；清零使用显式 `group reset`。组账期独立于节点账期，关机或漏跑后按当前
账期补偿重置。组用量随完整备份保存，达到配额由内核规则阻断；通知沿用现有
阈值和渠道。

面板：“流量统计、配额与限速 → 多节点共享配额”。

## Cloudflare Tunnel 多域名与路径

使用本地管理的命名 Tunnel UUID 和 credentials JSON。凭据可通过 Cloudflared
官方 `tunnel login` / `tunnel create NAME` 流程取得。

```bash
sb cloudflared install
sb tunnel managed 11111111-2222-3333-4444-555555555555 /root/tunnel-credentials.json
sb tunnel route add web app.example.com http://127.0.0.1:3001
sb tunnel route add api app.example.com http://127.0.0.1:9080 '^/api/'
sb tunnel route list
sb tunnel route remove api
```

在 Cloudflare 将域名 CNAME 指向 `<UUID>.cfargotunnel.com`，或自行使用
`cloudflared tunnel route dns UUID DOMAIN`；管理器不自动修改云端 DNS。
回源限定本机 HTTP(S)，路径规则优先于整个域名，同类规则按列表顺序匹配，
末尾添加 404。调用 Cloudflared 校验 ingress，失败时恢复状态和原服务。
既有 fixed/quick 模式保留，同一时间运行一个模式。

面板：“7. CF Tunnel → 配置多域名/路径转发到本机 HTTP 服务”。

## Snell 分享与客户端导入

`sb share NODE_ID` 和面板分享功能优先显示可复制的 Surge 原生配置，放入
Surge 配置文件的 `[Proxy]` 段即可。单节点还保存 `surge.conf`；批量分享先显示
全部可用 Snell 原生行，再显示其他协议链接，并保存 `snell-surge.conf`。
这些文件与凭据一样按 0600 保存。

服务端 v5 导出 Surge 兼容的 `version=4`，v6 需要支持 v6 的 Surge。
sing-box 多用户 Snell 不兼容 Surge，不生成误导的原生行；请用主菜单 5 或
节点菜单导出 sing-box 配置。Snell 分享页不再重复显示通用 URI 和二维码，
程序使用的 `share.txt` / `links.txt`、sing-box JSON 和 Sub-Store 兼容订阅仍保留。
此次调整不更改节点凭据或已有客户端连接。

## Sub-Store 使用入门

Sub-Store 是**订阅整理工具**。它把本机、其他 VPS 或已有订阅的节点整理成
一份，可在网页里筛选、改名，再按 Surge、mihomo/Clash、sing-box 等客户端
支持的格式导出。它不创建代理线路，也不会给客户端增加原本不支持的协议。
只使用一个节点时直接导入分享内容即可，无需安装 Sub-Store。

在“20. Sub-Store 订阅管理”选择“11. 首次设置”，会安装或启用组件，把本机
节点接入 `sb-manager` 来源，加入 `sb-manager-all` 组合，并显示访问方法。
已有安装会复用，节点变更后无需重新运行向导。选“12. 使用指南”可随时查看说明。

首次使用流程：

1. 完成首次设置，选择“5. 打开管理网页”。
2. 在自己的电脑执行面板提供的 SSH 转发命令，替换服务器 IP、用户名和实际
   SSH 端口。默认示例：`ssh -N -L 3001:127.0.0.1:3001 -p 22 root@YOUR_VPS_IP`。
3. 保持连接，在该电脑浏览器打开 `http://127.0.0.1:3001/`；网页要求后端地址时，
   填入面板显示的完整后端 URL（含随机访问路径）。无需在 UFW 开放 3001。
4. 打开 `sb-manager-all` 组合，选择客户端格式，导出内容并导入客户端。
   单用户 Snell 可选择 Surge；多用户 Snell 请通过主菜单 5 直接导出 sing-box 配置。
5. 合并其他服务器时，选择“9. 接入其他 VPS/订阅并合并来源”，填写中心机
   能访问的订阅地址。来源服务器无需安装 Sub-Store。

“来源”是一份输入订阅，“组合”合并多个来源。动态订阅在客户端刷新时读取
最新节点，不会主动推送到客户端。SSH 转发结束后本机地址不再可用；手机等
设备需要长期自动刷新时，须另行配置可访问的 HTTPS/CF Tunnel 入口。
首次设置不会自动创建公网入口，`127.0.0.1` 不能直接作为其他设备的公网订阅地址。
后端 URL 和订阅 URL 含访问凭据，应当保密。

## Sub-Store 生命周期与节点同步

```bash
sb substore install --port 3001
sb substore update --version 2.39.9 --frontend-version 2.32.2
sb substore status --json
sb substore access
sb substore sync sb-manager
sb substore backup /root/substore-backup.tar.gz
sb substore restore /root/substore-backup.tar.gz
sb substore disable
sb substore enable
```

按需安装发行版 Node.js 和 Python，下载官方后端 bundle 与前端 Release，并
通过 Release API 的 SHA-256 校验。只监听 `127.0.0.1`，后端使用随机访问路径；
`access` 显示前后端地址。可用 SSH 转发，或显式配置 Tunnel 路由访问。

`sync` 一次接入本机动态来源，后续节点变更自动更新，再次执行复用有效令牌。
首次执行也会把来源加入默认组合 `sb-manager-all`。原有本地订阅在对同名来源
执行 `sync` 时转为动态来源，已有处理规则保留。凭据保存在 secrets 目录，程序和数据位于
`/var/lib/sb-manager/substore/`。服务使用现有服务账号，支持 systemd/OpenRC。
更新或恢复失败会回退程序、数据和设置。

独立备份和完整 `sb backup` 都包含 Sub-Store 数据；备份期间短暂停止正在运行
的 Sub-Store 以取得一致副本，再恢复服务。备份含访问路径和订阅凭据，权限为
0600。普通卸载停止组件并保留数据，彻底卸载才删除。完整恢复沿用 128 MiB
压缩 / 512 MiB 解压上限；独立恢复为 128 MiB 压缩 / 256 MiB 解压上限。

面板主菜单：“20. Sub-Store 订阅管理”。

## 多服务器接入与动态订阅（alpha.34）

只有中心服务器需要安装 Sub-Store。其他使用 sb-manager 的服务器提供动态
订阅地址，中心登记一次，客户端以后更新组合订阅时自动拉取最新节点。
节点增删、启停、地址/端口变更、用户变更和凭据轮换都会更新动态内容。
客户端仍需按自身的订阅刷新周期拉取，已导入的配置不会被主动推送替换。

在每台来源服务器创建动态地址：

```bash
sb subscription create never mixed --live --base-url https://sub.example.com
# 或仅在 30 天内有效：
sb subscription create 30d mixed --live --base-url https://sub.example.com
```

`--base-url` 填写**已配置好**的 HTTPS 入口，需把 `/sub/` 请求转发到该服务器
的 `127.0.0.1:9080`。可使用已有 Tunnel 路由或 TLS 反向代理；该选项只生成
对外链接，不配置域名、DNS、TLS 或防火墙。使用 SSH 转发时可省略此选项，
登记中心机能够访问的本机转发地址。来源服务器只需订阅服务的 Python 依赖。

在中心机接入本机和远程来源：

```bash
sb substore sync local-server
sb substore source add server-b 'https://sub.example.com/sub/TOKEN?format=substore'
sb substore source list
sb substore source check server-b
sb substore source remove server-b
# 最后一个参数可选择另一个组合；默认 sb-manager-all：
sb substore source add server-c 'https://other.example.com/sub/TOKEN?format=substore' my-servers
```

打开 Sub-Store 网页中的 `sb-manager-all` 组合，选择支持所用协议的客户端
格式并导出订阅。后续无需复制节点或重建组合。添加同名来源更新其 URL，并
保留处理规则；加入组合时保留已有成员顺序和其他设置。移除来源由 Sub-Store
清理组合中的引用，不自动撤销原服务器令牌。其他脚本的 HTTPS 订阅也可接入。
来源地址不接受 URL 用户名/密码、空白或 `#` 片段；系统自动添加 `#noCache`
参数，确保拉取时读取最新内容。源站不可达时由 Sub-Store 报告拉取失败。

面板入口：“20. Sub-Store 订阅管理 → 将本机节点接入订阅组合/接入其他 VPS
与订阅并合并来源/管理本机动态订阅 URL”。来源 URL 在输入时隐藏，列表不显示 URL 或令牌。
面板会根据已有的整域名 Tunnel 路由建议 HTTPS 入口；首次仍须配置网络可达性。

`--live` 为显式启用选项；不带它创建的订阅仍是有期限的快照。`never` 仅用于
动态订阅，表示持续有效直至撤销，并允许访问以后新增的启用节点。令牌只在
创建时显示，节点变更不会换令牌；发现泄露时在来源服务器按 ID 撤销并重新接入：

```bash
sb subscription list
sb subscription revoke SUBSCRIPTION_ID
```

状态事务成功后，管理器把当前订阅内容写入一个原子替换的文件。订阅 HTTP
服务继续使用低权限账号，只读预生成内容；生成失败会触发状态回滚。完整
备份保留动态元数据，恢复后重新发布与恢复状态一致的内容。Sub-Store 接入
失败会尝试还原来源和组合；API 持续不可用时保留受保护的原定义供恢复。

## tc 下行平滑限速

```bash
sb deps install shaping
sb traffic set mixed-main --download-rate 50M --upload-rate 20M
sb traffic shaping plan eth0 --capacity 1G
sb traffic shaping enable eth0 --capacity 1G
sb traffic shaping status --json
sb traffic shaping disable
```

对所选网卡上直连节点的**下行**执行 HTB + fq_codel 排队整形。容量参数是
该网卡总整形上限，也涵盖同一网卡的其他流量，应填写实际链路容量。上行、
Tunnel/TCP-SNI 复用的 loopback 回源和其他网卡的流量继续使用 nftables 限速；预览列出
适用和排除节点。

只接管内核默认 noqueue/mq/fq/fq_codel，或管理器之前恢复的相同队列。自定义
队列、过滤器或无法还原的参数会被拒绝。原队列记录保存在
`/var/lib/sb-manager/shaping/`。调整失败尝试回滚，停用或卸载时恢复；恢复失败
保留记录并中止卸载。默认安装不启用整形。

面板：“流量统计、配额与限速 → tc 下行平滑限速”。
