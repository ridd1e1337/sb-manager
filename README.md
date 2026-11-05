# sb-manager

`sb-manager` 是 sing-box 的中文管理脚本，支持 systemd 和 OpenRC。安装后运行 `sb`，按面板提示添加节点、申请证书和导入客户端。

当前版本：`0.1.0-alpha.54`

## 第一步：安装

所有支持的 Linux 系统使用同一个安装入口。请用 root 执行；非 root 用户在命令前加 `sudo`：

```bash
curl -fsSL https://github.com/ridd1e1337/sb-manager/raw/refs/heads/main/install.sh | bash
```

安装器会自动识别 systemd/OpenRC，安装管理器和最新 sing-box，并默认开启管理器每日自动更新。

Alpine 的最小镜像通常没有 Bash、curl 和 tar，先执行一次：

```bash
apk add --no-cache bash curl tar ca-certificates
```

然后仍使用上面的安装命令。支持 Debian、Ubuntu、Alpine、Rocky、Alma、Fedora、Arch 和 openSUSE；系统必须实际运行 systemd 或 OpenRC。安装时可追加 `--no-menu`，固定核心版本可追加 `--core-version VERSION`。

## 第二步：使用

打开交互面板：

```bash
sb
```

常用流程：

1. 选择“添加节点”，选择协议并填写地址、端口和域名。
2. 需要 TLS 的协议直接输入 Cloudflare 托管的域名；没有可用证书时，自动添加指向本机公网 IP 的 DNS 记录（关闭橙云），再申请证书。首次填写 API Token 和邮箱，之后自动复用。
3. 创建完成后复制分享链接、二维码或 sing-box 配置，导入客户端。

Token 需要目标区域的「Zone:Read」和「DNS:Edit」权限。已有可用证书直接复用；已有 DNS 指向其他地址或开启橙云时会提示处理，建议为节点使用独立子域名。命令行添加 TLS 节点也支持自动准备 DNS 和证书，详见[域名与证书自动准备](docs/OPERATIONAL_FEATURES.md#节点域名与证书自动准备alpha52)。

常用命令：

```bash
sb status                         # 查看服务和节点
sb node list                     # 列出节点
sb share NODE_ID                 # 显示节点分享内容
sb node show NODE_ID             # 查看节点详情
sb update                        # 手动更新管理器脚本
sb update auto status            # 查看每日自动更新状态
```

管理器安装和 `sb core update` 默认跟随 sing-box 最新稳定 Release。协议添加还支持把当前核心的新增字段直接写入节点：

```bash
sb node add trojan --id edge --domain edge.example.com --address edge.example.com \
  --sing-box-inbound-json '{"tcp_fast_open":true,"tls":{"alpn":["h2","http/1.1"]}}' \
  --sing-box-outbound-json '{"tcp_multi_path":true,"connect_timeout":"10s"}'
```

参数也可以使用 `@/path/to/fields.json`。扩展会同时进入服务端 inbound 和 sing-box 客户端 outbound，实际字段由已安装核心校验；管理器继续接管协议类型、标签、地址、端口、用户和凭据。ShadowTLS 等复合协议可在 JSON 中使用 `by_tag` 按生成的 tag 指定扩展。修改已有节点使用相同参数：`sb node set NODE_ID --sing-box-inbound-json @FILE`。

新建 Snell 节点的 PSK 和 userkey 会持续保留，普通脚本更新不会使客户端突然失效。只有执行 `sb node rotate`、`sb user rotate` 或把单用户节点改成多用户时，才需要重新导入客户端。

多个 TLS 节点可以使用内置 TCP/SNI 复用：

```bash
sb mux auto all --port 443 --backend sing-box
```

如果 443 已由 Nginx/Caddy 网站占用，运行一次：

```bash
sb mux setup
```

自动识别网站程序、备份配置、补齐所需模块并接入 SNI 分流。此后添加、删除、启停 TCP/TLS 节点会自动同步，分享链接使用公网 443，后端只监听本机。也可在“全局设置 → TCP/443 多协议复用 → 一键接入现有 Nginx/Caddy 网站”操作；恢复入口用 `sb mux detach`。UFW、SSH 和 Fail2ban 设置保持不变。支持范围和迁移边界见[网站一键接入](docs/OPERATIONAL_FEATURES.md#nginxcaddy-网站一键接入alpha54)。

更多协议参数、安全边界、证书、Sub-Store、备份和高级功能见：

- [协议安全边界](docs/PROTOCOL_SECURITY.md)
- [可选运维功能](docs/OPERATIONAL_FEATURES.md)
- [状态文件说明](docs/STATE_SCHEMA.md)
