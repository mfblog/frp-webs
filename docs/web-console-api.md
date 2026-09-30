# Web 控制台 API

所有响应使用 JSON：

```json
{"ok": true, "data": {}}
```

失败响应：

```json
{"ok": false, "message": "错误说明"}
```

API 不提供登录认证，访问控制应由内网、防火墙和网络策略负责。所有写请求要求 `application/json` 并执行同源检查；跨站来源会被拒绝。

## GET /api/status

返回 frpc 服务状态和发现结果：

```json
{
  "ok": true,
  "data": {
    "service": "frpc.service",
    "active": "active",
    "enabled": "enabled",
    "version": "0.68.1",
    "config_exists": true,
    "config_mtime": 1780000000,
    "frpc_bin": "/usr/local/frpc/frpc",
    "config_path": "/usr/local/frpc/frpc.toml",
    "discovery": {
      "binary": "/usr/local/frpc/frpc",
      "config": "/usr/local/frpc/frpc.toml"
    }
  }
}
```

## GET /api/config

```json
{
  "ok": true,
  "data": {
    "content": "serverAddr = \"example.com\"\n",
    "exists": true,
    "revision": "1780000000000000000:35"
  }
}
```

## POST /api/verify

```json
{"content": "serverAddr = \"example.com\"\n"}
```

只校验，不写入磁盘。

## POST /api/config

```json
{
  "content": "serverAddr = \"example.com\"\n",
  "restart": true,
  "revision": "1780000000000000000:35"
}
```

处理顺序：校验、revision 检查、备份、原子写入、可选启动/重启。冲突返回 HTTP 409，校验失败返回 HTTP 400，启动失败返回 HTTP 500 并执行回滚。

## POST /api/service

```json
{"action": "restart"}
```

支持 `start`、`stop`、`restart`。启动和重启前会重新校验磁盘中的配置。

## GET /api/update

打开控制台时调用，向 GitHub 查询 frp 最新正式 Release，并与本机 `frpc --version` 比较：

```json
{"ok": true, "data": {"current": "0.68.0", "latest": "v0.68.1", "available": true}}
```

优先直连 GitHub API；若直连不可用，经 `https://ghfast.top/` 获取官方 Release 最新版本页面与 `frp_sha256_checksums.txt`。两条路径均失败才返回错误；不会自动下载或更新。

## POST /api/update

用户在更新提示中确认后发送：

```json
{"version": "v0.68.1"}
```

后端重新核对版本，下载当前 Linux CPU 架构对应的官方 frp Release 安装包，校验 Release SHA256 摘要，检查二进制版本并使用新版本校验现有配置。更新时保留配置和服务原有启用/运行状态；运行中的服务会短暂重启，启动失败则尝试回滚旧二进制和服务。版本已变化或并发更新返回 HTTP 409。需确保控制台进程有权限写入 frpc 二进制目录、管理 systemd 服务，并能直连 GitHub 或访问 `https://ghfast.top/`。下载优先直连；直连失败后使用加速地址，最终仍校验 SHA256。

## GET /api/logs

```text
GET /api/logs?lines=300
```

`lines` 范围为 1–1000，默认 120。返回：

```json
{"ok": true, "data": {"logs": "journalctl 输出"}}
```

## 安全限制

- JSON 请求体最大约 1 MiB
- 未知 JSON 字段和尾随内容会被拒绝
- 响应包含 CSP、`X-Content-Type-Options`、`X-Frame-Options` 等安全头
- API 不应直接暴露到不受信网络
