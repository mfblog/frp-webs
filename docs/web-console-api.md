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
