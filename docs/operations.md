# 运维说明

## 服务与文件

| 服务 | 二进制 | 配置/环境文件 |
| --- | --- | --- |
| `frps.service` | `/usr/local/frps/frps` | `/usr/local/frps/frps.toml` |
| `frpc.service` | `/usr/local/frpc/frpc` | `/usr/local/frpc/frpc.toml` |
| `frpc-web.service` | `/usr/local/frpc/web/frpc-web` | 无 |

`frpc-web` 是包含 Vue 静态资源的单一 Go 二进制，不依赖 Python、Node.js 或独立页面文件。

## frpc 安装语义

1. 下载并安装 frpc。
2. 写入 `frpc.service`。
3. 如果已有 `frpc.toml`，先校验再决定是否启动；不会覆盖原配置。
4. 如果没有配置，保持 `frpc.service` disabled/stopped。
5. 从 GitHub Release 下载当前 CPU 架构对应的 `frpc-web-linux-*`。
6. 下载 `SHA256SUMS` 并校验控制台二进制。
7. 写入并启动 `frpc-web.service`。
8. 用户在网页保存有效配置后，再启用并启动 frpc。

## Web 控制台启动参数

systemd 默认执行：

```text
/usr/local/frpc/web/frpc-web \
  --listen 0.0.0.0:7410 \
  --frpc-bin /usr/local/frpc/frpc \
  --frpc-config /usr/local/frpc/frpc.toml \
  --frpc-service frpc.service
```

支持参数：

- `--listen`
- `--frpc-bin`
- `--frpc-config`
- `--frpc-service`

控制台不提供登录认证；默认监听所有网卡，只应在可信内网中使用，并通过防火墙限制访问来源。

如果没有显式指定 frpc 路径，控制台依次检查：

1. `frpc.service` 的 `ExecStart`
2. `/usr/local/frpc/frpc`
3. `PATH` 中的 `frpc`

配置路径依次使用显式参数、`ExecStart` 中的 `-c/--config`，最后回退到 frpc 二进制同目录的 `frpc.toml`。

## 配置保存与回滚

- 请求体和配置正文最大为 1 MiB
- 保存前执行 `frpc verify -c <临时文件>`
- 配置使用 `0600` 权限和同目录原子重命名写入
- 旧配置备份为 `frpc.toml.bak.<时间戳>`
- 保存请求携带 revision；磁盘内容已变化时返回 HTTP 409
- 首次保存并启动失败：删除本次新配置，恢复原 enabled/active 状态
- 已有配置重启失败：写回旧配置并恢复服务状态
- `systemctl restart` 后会有限轮询 `is-active`，避免立即退出时误报成功

## 更新与卸载

更新 frpc 时会校验现有配置、备份旧二进制，并在新版本启动失败时恢复旧版本。Web 控制台会同时刷新到最新 GitHub Release。

卸载 frpc 会删除：

- `/usr/local/frpc`
- `frpc.service`
- `frpc-web.service`

## 网络和权限

- 默认监听 `0.0.0.0:7410`
- 控制台不提供登录认证，任何可访问端口的客户端都能修改 frpc 配置并控制服务
- 写接口检查 Origin 和 `Sec-Fetch-Site`，这只能缓解跨站请求，不能代替身份认证
- 必须通过防火墙/网络策略限制到受信内网客户端；不要将端口直接暴露到公网
