# AnyTLS 证书验证

AnyTLS 服务端需要证书和私钥。管理器使用 `--domain` 对应的
`/etc/sb-manager/certs/<domain>/{fullchain.pem,key.pem}`；缺少证书时拒绝添加启用节点，
并回滚事务。面板通过证书菜单签发和选择证书，不提供“忽略证书错误”的捷径。

客户端还必须验证证书链、有效期和域名，才能确认连接的是预期服务器。
跳过验证仍可能保留传输加密，但会失去正常的服务器身份认证，存在中间人攻击风险。
申请了可信证书也不能弥补客户端关闭验证。使用私有 CA 时应在客户端明确配置受信任的 CA，
而非启用 `insecure`。

## 导出策略

- AnyTLS URI：`insecure=0&allowInsecure=0`。
- sing-box JSON：`tls.enabled=true`、`tls.insecure=false`，`tls.server_name` 为证书域名。
- 连接地址可以为 IP，SNI/验证域名仍保持证书域名。
- `fp=chrome`/uTLS 只调整 ClientHello 指纹，不关闭证书验证。

旧版本的 URI 已使用 `insecure=0`，原生 sing-box JSON 未写 `insecure` 时默认也会验证。
alpha.36 将 JSON 的 `false` 明确写出，并添加 v2rayN 兼容参数 `allowInsecure=0`。
Sub-Store 2.43.1 和 2.44.2 的 V2Ray URI 输出会省略 `skip-cert-verify=false` 对应的
`insecure=0`，但 AnyTLS 转换会保留这个兼容参数。它可避免部分旧版 v2rayN
（例如 7.18.0）在参数缺失时继承全局 `DefAllowInsecure`。最新版客户端的导入行为可能不同，
应以实际生成的配置为准。

该兼容参数不能阻止订阅处理器主动覆盖设置。Sub-Store 的“快捷设置”中，
`scert=ENABLED` 表示**启用跳过证书验证**，会把输入的 `skip-cert-verify=false`
改成 `true`；`scert=DEFAULT` 才是保留来源设置。

## v2rayN / Sub-Store 排查

1. 检查原始 AnyTLS 链接应有 `insecure=0`，alpha.36 起还有 `allowInsecure=0`。
2. 检查 Sub-Store 单个来源和订阅组合的“快捷设置”，将“跳过证书验证”恢复为“默认/沿用来源”。
   检查后续脚本是否重新写入 `skip-cert-verify`、`insecure` 或 `allowInsecure`。
3. 在 Sub-Store JSON 预览中确认 AnyTLS 的 `skip-cert-verify=false`、SNI 为证书域名。
   V2Ray 格式不应出现 `insecure=1` 或 `allowInsecure=1`。
4. 在 v2rayN 更新订阅，打开节点确认“跳过证书验证/允许不安全连接”关闭。
   如果仍保留旧值，检查客户端全局默认值、订阅覆盖选项和最终 sing-box 配置中的 `tls.insecure`。
5. 若开启验证后无法连接，检查证书有效期、完整证书链、SNI 和系统时间。
   不要用开启跳过验证来掩盖这些错误。

升级管理器用 `sb update`。重新生成分享链接或订阅后，新参数才会出现；
之前手工粘贴进 Sub-Store 的静态内容需要重新导入。现有动态订阅可通过
`sb substore sync` 重新发布；普通快照订阅需要重新创建。
即使来源正确，Sub-Store 中强制启用跳过验证的处理器仍须单独修正。

参考：[AnyTLS URI 规范](https://github.com/anytls/anytls-go/blob/main/docs/uri_scheme.md)、
[Sub-Store URI 输出](https://github.com/sub-store-org/Sub-Store/blob/2.43.1/backend/src/core/proxy-utils/producers/uri.js)、
[v2rayN 7.18.0 参数解析](https://github.com/2dust/v2rayN/blob/7.18.0/v2rayN/ServiceLib/Handler/Fmt/BaseFmt.cs)。

## 验证记录

`tests/anytls-tls-smoke.sh` 使用临时目录、临时 CA 和本机回环监听，验证缺少证书时事务回滚、
可信证书完整 AnyTLS 转发成功、不可信 CA 被拒绝、域名不匹配被拒绝。
`tests/anytls-substore-smoke.sh` 使用独立 Sub-Store 数据目录，验证 IPv4/IPv6 链接经过
快捷设置覆盖、恢复默认以及 V2Ray 转换后，证书验证参数和 SNI 得到保留。

2026-10-27，alpha.36 验证范围：

| 环境 | 验证 |
| --- | --- |
| 本地 Ubuntu，官方 sing-box 1.13.19 | 协议/事务套件、AnyTLS 证书验证、动态订阅 |
| 本地 sing-box 1.15.0-alpha.2 | AnyTLS 证书验证、含 Snell 的订阅快照 |
| Sub-Store 2.43.1 / 2.44.2 官方 bundle | IPv4/IPv6、快捷设置覆盖及恢复、V2Ray URI 转换 |
| Alpine 3.23 容器 | sing-box 1.13.19 证书验证、两版 Sub-Store 转换 |
| 用户提供的 Debian 13 ARM64 主机 | 临时目录及回环端口，sing-box 1.14.4 证书验证、Sub-Store 2.43.1 转换 |

本次下载的测试资产均核对 GitHub Release SHA-256 digest。远程使用的 Sub-Store bundle
也与 2.43.1 官方 digest 一致。另检查实际订阅输出，并以系统信任库验证其 7 个不同
AnyTLS 端点的证书链和域名；全部通过。未在用户客户端执行 GUI 导入操作。
本次远程测试为专项隔离验证，未运行完整 `remote-debian13-suite.sh`，
未执行安装、系统服务变更或主机防火墙变更。
