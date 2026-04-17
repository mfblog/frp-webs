# Web 控制台 API

本文档描述 `frpc Web 控制台` 当前实际提供的 HTTP 接口。

## 说明

- 当前接口没有版本号，路径直接以 `/api/*` 暴露
- 当前接口没有内建鉴权
- 返回结构统一为 JSON

成功响应示例：

```json
{
  "ok": true,
  "data": {}
}
```

失败响应示例：

```json
{
  "ok": false,
  "message": "错误说明"
}
```

## GET /api/status

读取 `frpc.service` 当前状态。

返回字段：

- `service`
- `active`
- `enabled`
- `version`
- `config_exists`
- `config_mtime`

示例：

```json
{
  "ok": true,
  "data": {
    "service": "frpc.service",
    "active": "active",
    "enabled": "enabled",
    "version": "0.65.0",
    "config_exists": true,
    "config_mtime": 1776412345
  }
}
```

## GET /api/config

读取当前 `frpc.toml` 的全文。

示例：

```json
{
  "ok": true,
  "data": {
    "content": "serverAddr = \"example.com\""
  }
}
```

## GET /api/logs

读取最近 120 行 `frpc.service` 日志。

示例：

```json
{
  "ok": true,
  "data": {
    "logs": "Apr 17 12:00:00 ..."
  }
}
```

## POST /api/verify

校验提交的配置内容，但不写入磁盘。

请求体：

```json
{
  "content": "serverAddr = \"example.com\""
}
```

成功：

```json
{
  "ok": true,
  "message": "配置校验通过"
}
```

失败时返回 `400`：

```json
{
  "ok": false,
  "message": "frpc verify 输出"
}
```

## POST /api/config

写入配置，并可选重启 `frpc`。

请求体：

```json
{
  "content": "serverAddr = \"example.com\"",
  "restart": true
}
```

行为：

- 先校验内容
- 再写入配置文件
- 如果 `restart=true`，则执行 `systemctl restart frpc.service`
- 如果重启失败，会自动回滚到上一份配置并尝试恢复服务

成功：

```json
{
  "ok": true,
  "message": "配置已保存，frpc 已重启"
}
```

失败时通常返回 `400` 或 `500`：

```json
{
  "ok": false,
  "message": "frpc 重启失败，已回滚到上一份配置并恢复服务"
}
```

## POST /api/service

执行服务动作。

请求体：

```json
{
  "action": "restart"
}
```

允许的动作：

- `start`
- `stop`
- `restart`

成功：

```json
{
  "ok": true,
  "message": "frpc 已执行 restart"
}
```

## 已知限制

- 当前没有鉴权、限流、CSRF 防护和 API 版本管理
- 当前接口面向本机运维，不适合直接公网暴露
- 返回结构以当前脚本实现为准，未来若修改脚本，接口也会跟着变化
