# 协议安全边界

以下结论基于当前协议渲染器、节点凭据管理和客户端导出代码的阅读。
这是配置与实现范围说明，不是完整安全审计或第三方认证。

| 协议 | 当前配置与结论 |
| --- | --- |
| AnyTLS | 服务端证书、随机用户密码、客户端 SNI 和显式 `insecure=false`；分享链接明确关闭跳过验证。 |
| Hysteria2、Trojan、TUIC、NaiveProxy | 服务端证书和用户认证；原生 sing-box 出站设置 SNI，未启用 `insecure`，由核心默认验证证书。TUIC 显式关闭 0-RTT。 |
| VLESS TLS | 强制 TLS，UUID 认证；客户端按证书域名验证。URI 的 `encryption=none` 表示 VLESS 本身不另加密，外层 TLS 仍提供加密。 |
| VLESS Reality | 生成独立密钥对和 Short ID；客户端使用公钥、Short ID、SNI 和 uTLS，不能与关闭普通证书验证混为一谈。 |
| VMess WS + Cloudflare Tunnel | VMess 用户 UUID、客户端 TLS 验证；WS 回源默认只监听 loopback。Cloudflare 是 TLS 入口链路中的参与方。 |
| Shadowsocks 2022 | 仅提供 2022 AEAD 算法和随机密钥，默认 AES-256-GCM；无需 X.509 证书，安全依赖密钥保密。 |
| Snell v5/v6 | 使用随机节点 PSK；单用户轮换更换 PSK，多用户固定要求 userkey，不随启用人数减少而降级。 |
| ShadowTLS v3 | 外层证书验证和用户认证，内层 Shadowsocks 2022 加密；服务端与客户端均生成完整 detour 链路。 |
| SOCKS5、HTTP、mixed | 随机用户名/密码，默认监听 `127.0.0.1`；协议不提供传输加密，凭据和代理流量不适合直接暴露到不可信网络。 |

## 凭据与链路策略

### ShadowTLS 双层配置

`protocols/shadowtls.sh` 将 v3 握手、外层用户认证与 Shadowsocks 2022 加密组合。
每个用户的外层密码和内层密钥分别随机生成；内层另有独立节点服务端密钥。
停用或删除用户会同时从两层认证列表移除该用户，轮换会同时更换其两层凭据。

内层使用 `2022-blake3-aes-128-gcm`，仅在 `127.0.0.1` 上分配临时 TCP 端口。
客户端先用内层 SS outbound 封装请求，再经其 `detour` 进入 ShadowTLS 外层；
外层显式设置 `insecure=false`。服务端执行相反的转接顺序。

单节点 JSON 导出包含两个 outbound，完整配置和动态订阅也会保留这两项。
分享链接为带 `shadow-tls` 插件参数的 `ss://`，只适用于支持该组合的客户端或转换器。
旧版只有外层的 `shadowtls://` 链接必须重新导入。

参考：[ShadowTLS 官方说明](https://github.com/ihciah/shadow-tls#how-to-use-it)。

### Snell 的用户轮换和撤销

新建节点以 `credential_mode=single` 保留 Surge/mihomo 的 PSK 兼容性。
单用户轮换会真正更换节点 PSK；添加第二个用户后改为 `multi`，之后停用、删除用户
都不会退回单用户模式，即使只剩一个启用用户也继续要求 userkey。
多用户轮换仅替换目标 userkey，不改变其他用户凭据；该模式需要支持 userkey 的 sing-box 客户端。

alpha.38 对旧节点进行一次凭据迁移：Snell 更换旧 PSK，避免早期已删用户仍持有可用 PSK；
ShadowTLS 补齐独立内层密钥。迁移与节点修改、备份恢复、动态订阅发布沿用完整快照/回滚事务，
新配置必须通过已安装核心的运行时配置校验。受影响的客户端需要重新导入。
静态订阅不会自动改写；恢复未迁移的旧备份也会执行迁移。恢复已迁移的备份会恢复其中的凭据，
可能恢复备份之后撤销的访问，因此不能用旧订阅内容判断当前访问权限。

### 明文入口及辅助服务

普通 SOCKS5/HTTP/mixed 的密码认证不等于链路加密。需要跨不可信网络使用时，
应通过 SSH/VPN 等受保护通道接入，或选择有加密传输的协议。
Hysteria Realm 辅助服务仍允许明文 HTTP 配置并给出提示；公网使用时应配置 HTTPS，
避免认证令牌通过明文连接传输。

## 导出与运行环境

Sub-Store 的来源、组合和脚本处理器可以覆盖原始节点的 TLS 设置。
客户端全局默认值、导入格式和订阅转换器也会影响最终配置。原始 URI 或原生 JSON
符合预期，不能证明所有第三方转换结果都保留了相同策略。
具体说明见 [AnyTLS 证书验证](ANYTLS_TLS_VERIFICATION.md)。

systemd 配置使用 `sbmanager` 账户；OpenRC 的 sing-box 服务为兼容受限 VPS 内核
以 root 运行，两者不能概括为相同的最低权限部署。应用配置校验、证书部署校验、
原子写入和失败回滚属于运行保护机制。
