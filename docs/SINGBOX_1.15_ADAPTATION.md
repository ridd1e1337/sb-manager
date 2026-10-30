# sing-box 1.15 适配记录

管理器的内置字段继续使用 1.13/1.14 已验证的协议字段，版本门控通过
`version_ge` 比较完整版本号，因此 sing-box 1.15 不需要额外的状态迁移。
需要立即使用新核心字段时，可在添加或编辑任意节点时传入
`--sing-box-inbound-json` / `--sing-box-outbound-json`；这些扩展会原样保留，
并在安装前交给当前核心的 `sing-box check` 校验。

将 1.14.0-rc.4 与 1.15.0-alpha.2 的核心 schema 做递归比较后，当前版本只有
`CacheFileOptions` 从 `rdrc_timeout` 调整为 `buffer_size`、`flush_interval`。
sb-manager 生成配置没有使用 cache-file 字段，因此现有 state、renderer 和导出
格式无需迁移；以后若引入缓存文件配置，必须按核心版本分别渲染。

适配策略：

1. 稳定安装默认仍跟随 GitHub 最新非 prerelease Release；当前离线 fallback 为
   已校验的 1.14.4。1.15 alpha 只通过
   `sb core channel preview` 选择，不会自动替换稳定核心。
2. 每次切换核心都继续执行配置 `check`、build tag 检查和配对回滚；失败时恢复
   原核心、配置和状态。
3. 只有确认 1.15 新字段的官方 schema、行为和客户端兼容性后，才新增状态字段和
   renderer 分支。

升级前建议：

```bash
sb backup /var/lib/sb-manager/backups/pre-1.15.tar.gz
sb core channel preview
sb core update 1.15.0-alpha.2
sb config validate
sb status --json
```

如果 1.15 正式版引入配置变更，应先导出新核心 schema，与
`docs/STATE_SCHEMA.md` 和生成配置逐项比较，再提交版本门控和迁移逻辑。
