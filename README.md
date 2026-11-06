# sb-manager

`sb-manager` 以 sing-box 一键安装和多协议节点管理为主，支持 systemd 和 OpenRC，并提供可选的新 VPS 基础初始化。安装后运行 `sb`，按面板提示添加节点、申请证书和导入客户端。

当前版本：`0.1.0-alpha.63`

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

然后仍使用上面的安装命令。支持 Debian、Ubuntu、Alpine、Rocky、Alma、Fedora、Arch 和 openSUSE；系统必须实际运行 systemd 或 OpenRC。安装时可追加 `--no-menu`，固定核心版本可追加 `--core-version VERSION`。

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

1. 选择“添加节点”，选择协议并填写地址、端口和域名。
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
```

管理器安装和 `sb core update` 默认跟随 sing-box 最新稳定 Release。协议添加还支持把当前核心的新增字段直接写入节点：

```bash
sb node add trojan --id edge --domain edge.example.com --address edge.example.com \
  --sing-box-inbound-json '{"tcp_fast_open":true,"tls":{"alpn":["h2","http/1.1"]}}' \
  --sing-box-outbound-json '{"tcp_multi_path":true,"connect_timeout":"10s"}'
```

参数也可以使用 `@/path/to/fields.json`。扩展会同时进入服务端 inbound 和 sing-box 客户端 outbound，实际字段由已安装核心校验；管理器继续接管协议类型、标签、地址、端口、用户和凭据。ShadowTLS 等复合协议可在 JSON 中使用 `by_tag` 按生成的 tag 指定扩展。修改已有节点使用相同参数：`sb node set NODE_ID --sing-box-inbound-json @FILE`。

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

`sb update` 先处理管理脚本，再更新已接入管理的 Caddy；脚本没有新版本时仍会继续。现有每日任务执行相同流程，沿用原来的开关和服务器本地时间，无需另设任务。Caddy 升级先校验模块和网站配置，再切换并确认服务；失败恢复旧版。即使主版本未变，也会重新获取官方插件构建；程序摘要一致时不重启，下载失败不触发服务回滚。`--check` 只查询脚本及 Caddy 主程序版本，不下载插件构建。sing-box 与 cloudflared 继续使用各自的更新策略。详情见 [Caddy 程序维护](docs/OPERATIONAL_FEATURES.md#caddy-程序维护alpha59)。

安装后自动维护项目缓存与日志，最长约一天，并限制日志容量；成功下载和编译的临时目录立即删除。查看策略用 `sb maintenance status`，手动清理用 `sb maintenance run`。证书、凭据、规则、备份以及当前和回滚程序保留。迁移前的共享系统日志仍按宿主机策略管理。

更多协议参数、安全边界、证书、Sub-Store、备份和高级功能见：

- [协议安全边界](docs/PROTOCOL_SECURITY.md)
- [可选运维功能](docs/OPERATIONAL_FEATURES.md)
- [状态文件说明](docs/STATE_SCHEMA.md)
