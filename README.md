# frp 一键安装脚本与 Web 控制台

面向 Debian 12/systemd 的 frp 安装脚本，支持安装、更新和卸载 `frps` / `frpc`。安装 `frpc` 后会额外部署一个由 Go 编写的 Web 控制台，用户通过网页完成首次 `frpc.toml` 配置、服务控制和日志查看。

## 主要能力

- 保留 Shell 脚本原有的 frps/frpc 安装、更新、回滚和卸载流程
- 安装 frpc 时不生成示例配置，首次配置在网页中完成
- Go 后端与 Vue 3 + TypeScript + Tailwind CSS 前端编译为单一二进制
- 自动发现 frpc 二进制、配置路径和 `frpc.service`
- 配置校验、原子保存、revision 冲突保护和启动失败回滚
- 通过 systemd 启动、停止、重启 frpc
- 页面内查看 journalctl 日志，支持上下滚动、自动跟随和跳到最新
- 支持 `amd64`、`arm64`、`armv7` 和 `386`

## 安装

要求：

- Debian 12
- root 权限
- systemd
- 可以访问 GitHub API/Release，或显式配置可信 HTTPS 下载代理

```bash
chmod +x install_frp.sh
sudo ./install_frp.sh
```

菜单：

```text
1) 安装 frps 服务端
2) 安装 frpc 客户端
3) 更新 frps 服务端
4) 更新 frpc 客户端
5) 卸载 frps 服务端
6) 卸载 frpc 客户端
7) 查看当前安装状态
```

安装 frpc 时，脚本会：

1. 安装 `/usr/local/frpc/frpc`
2. 创建 `frpc.service`
3. 从本项目 GitHub Release 下载当前架构的 `frpc-web` 二进制
4. 使用 `SHA256SUMS` 校验下载结果
5. 安装并启动 `frpc-web.service`
6. 如果不存在 `frpc.toml`，保持 `frpc.service` 停止且禁用

安装完成后访问：

```text
http://<服务器IP>:7410
```

控制台无需登录，打开后即可填写完整的 `frpc.toml`。首次点击“保存并启动”后，控制台才会启用并启动 `frpc.service`。

## 默认路径

| 内容 | 路径 |
| --- | --- |
| frps | `/usr/local/frps/frps` |
| frps 配置 | `/usr/local/frps/frps.toml` |
| frpc | `/usr/local/frpc/frpc` |
| frpc 配置 | `/usr/local/frpc/frpc.toml` |
| Web 控制台 | `/usr/local/frpc/web/frpc-web` |
| systemd 服务 | `/etc/systemd/system/frpc-web.service` |

Web 控制台默认监听 `0.0.0.0:7410`，不提供登录认证，适用于可信内网环境。任何能访问 7410 端口的设备都可以修改配置和控制 frpc 服务；请勿将端口暴露到公网，并使用防火墙限制来源。

## Web 控制台布局

- 顶部：frpc 路径、版本和运行状态
- 左侧：`frpc.toml` 编辑器和保存操作
- 右侧：systemd 状态、启动、重启和停止
- 底部：可滚动日志面板
- 移动端：配置、状态和日志三个页签

日志面板每 5 秒刷新一次。启用“自动跟随”时停留在最新日志；用户向上滚动后自动暂停跟随，并显示“跳到最新”。

## 从源码构建

本地要求：Go 1.24、Node.js 20.19 或兼容版本。

```bash
npm ci --prefix web
npm run build --prefix web
go test ./...
go build -o frpc-web ./cmd/frpc-web
```

前端构建产物会写入 `cmd/frpc-web/static/`，随后由 `go:embed` 编译进 Go 二进制。运行二进制不需要 Node.js 或 Python。

## 服务管理

```bash
systemctl status frps
systemctl status frpc
systemctl status frpc-web
```

```bash
systemctl restart frpc
systemctl restart frpc-web
```

## 安全提醒

- 安装脚本以 root 身份写入 `/usr/local`、`/etc` 和 systemd 服务
- Web 控制台拥有修改 frpc 配置和控制 `frpc.service` 的权限
- 默认直接使用 GitHub HTTPS。确需代理时可设置 `FRP_GITHUB_ACCEL_PREFIX`，脚本只接受 HTTPS 前缀
- Release checksum 用于检测下载损坏；高安全场景仍建议增加独立签名校验
- 不要直接将 `7410` 端口暴露到公网

## 文档

- [运维说明](./docs/operations.md)
- [Web 控制台 API](./docs/web-console-api.md)
- [排障说明](./docs/troubleshooting.md)
