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
| Snell v5/v6 | 使用随机节点 PSK；多用户时还使用 userkey，但当前用户生命周期存在下述缺陷。 |
| ShadowTLS v3 | 当前只生成外层伪装传输，缺少内层加密代理及完整转接关系，不能视为完整的加密代理节点。 |
| SOCKS5、HTTP、mixed | 随机用户名/密码，默认监听 `127.0.0.1`；协议不提供传输加密，凭据和代理流量不适合直接暴露到不可信网络。 |

## 已知实现限制

### ShadowTLS 缺少内层组合

`protocols/shadowtls.sh` 生成 v3 握手目标、用户认证和严格模式配置，但没有生成
Shadowsocks 等内层入站、服务端 `detour`，也没有生成内层客户端出站。
ShadowTLS 官方说明其不负责应用数据加密和代理请求封装，需要与加密代理配合。
当前普通节点导出不能代表这套完整组合已经实现。

参考：[ShadowTLS 官方说明](https://github.com/ihciah/shadow-tls#how-to-use-it)。

### Snell 的用户轮换和撤销

`protocols/snell.sh` 在只剩一个启用用户时省略 `users`/`userkey`，改用节点 PSK。
`lib/node.sh` 的 Snell 用户轮换分支目前只更换 userkey，不更换节点 PSK。
因此单用户节点执行用户凭据轮换后，旧 PSK 链接仍可能有效；多用户减少到单用户时，
原持有者仍知道节点 PSK，不能仅凭停用某个 userkey 就认定其访问已撤销。
CLI 当前通用的“旧分享链接立即失效”提示不能用于证明上述 Snell 场景已经撤销。

在完善 PSK 轮换和用户模式转换之前，泄漏或需要撤销 PSK 时应停用旧节点，
新建独立 Snell 节点并重新分发凭据。当前问题尚未修复。

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
