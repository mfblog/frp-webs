# frp 一键安装脚本

一个面向 `Debian 12` 的 `frp` 安装脚本，支持交互式安装 `frps` 服务端、`frpc` 客户端、更新、卸载，以及 `frpc Web 控制台`。

![frpc Web 控制台预览](./image.png)

## 先看风险

- 脚本要求 `root` 权限运行，并会写入 `systemd` 服务与 `/usr/local/*` 安装目录。
- 当前默认启用了第三方 GitHub 加速代理：`http://154.17.224.29/rproxy?url=`。这是明文 HTTP 下载链路，当前版本仍未内置 checksum / 签名校验。
- `frpc Web 控制台` 默认提示监听 `0.0.0.0:7410`，且当前实现没有登录鉴权；如果暴露到公网，相当于直接开放了 `frpc` 管理入口。

如果你的使用场景对供应链安全或控制面暴露比较敏感，请先阅读：

- [运维说明](./docs/operations.md)
- [Web 控制台 API](./docs/web-console-api.md)
- [排障说明](./docs/troubleshooting.md)

## 功能特性

- 交互式安装 `frps` / `frpc`
- 自动生成 `systemd` 服务
- 生成基础 `frps.toml` / `frpc.toml`
- 支持更新与卸载
- 提供 `frpc Web 控制台`
- 支持查看当前安装状态
- 更新流程在切换前会先校验配置
- `frpc` / `frps` 更新后若启动失败，会自动回滚上一版二进制并尝试恢复服务
- Web 控制台“保存并重启”在重启失败时会自动回滚到上一份配置

## 前置条件

- 操作系统：`Debian 12`
- init 系统：`systemd`
- 权限：`root`
- 网络：能访问 GitHub API，或能访问脚本内配置的加速代理
- 架构：`amd64`、`arm64`、`arm`、`386`

脚本会自动安装这些依赖：

- `curl`
- `jq`
- `tar`
- `python3`

## 快速开始

```bash
chmod +x install_frp.sh
sudo ./install_frp.sh
```

运行后菜单如下：

```text
1) 安装 frps 服务端
2) 安装 frpc 客户端
3) 更新 frps 服务端
4) 更新 frpc 客户端
5) 卸载 frps 服务端
6) 卸载 frpc 客户端
7) 查看当前安装状态
```

## 安装路径

- `frps`：`/usr/local/frps`
- `frpc`：`/usr/local/frpc`
- `frpc Web 控制台`：`/usr/local/frpc/web`

关键文件：

- `frps` 配置：`/usr/local/frps/frps.toml`
- `frpc` 配置：`/usr/local/frpc/frpc.toml`
- Web 控制台配置：`/usr/local/frpc/web/panel.json`

## Web 控制台说明

安装 `frpc` 时，脚本会询问是否部署 `frpc Web 控制台`。

控制台支持：

- 在线编辑 `frpc.toml`
- 在线校验配置
- 保存配置
- 保存并重启 `frpc`
- 查看运行状态
- 查看最近日志

页面交互已补充：

- 操作中的 loading / 禁用态
- 配置未保存提示
- 刷新前覆盖确认
- `Ctrl/Cmd + S` 快捷保存
- 日志弹窗键盘交互与焦点管理

默认提示输入：

- 监听地址：`0.0.0.0`
- 监听端口：`7410`

强烈建议：

- 仅在本机或受限内网中使用
- 若必须对外暴露，请自行放在反向代理、鉴权与 TLS 后面
- 不要把“无需登录”的当前实现直接暴露到公网

## 失败路径与回滚语义

### 更新 `frps` / `frpc`

当前版本的更新流程会：

1. 先下载新版本到临时目录
2. 用新版本二进制校验现有配置
3. 通过后再停止旧服务并替换二进制
4. 启动新版本服务
5. 如果新版本启动失败，自动恢复上一版二进制并尝试重新拉起服务

注意：

- 目前回滚的是二进制文件，不是完整的系统快照
- 如果回滚后的服务也无法启动，需要结合 `systemctl status` 与日志排障

### Web 控制台“保存并重启”

保存时会先校验新配置，再写入配置文件。

- 如果只点“保存配置”，会保存并保留当前运行状态
- 如果点“保存并重启”，而 `frpc` 重启失败，脚本会自动回滚到上一份配置并尝试恢复服务

## systemd 服务

脚本会创建或使用这些服务：

- `frps.service`
- `frpc.service`
- `frpc-web.service`

常用命令：

```bash
systemctl status frps
systemctl status frpc
systemctl status frpc-web
```

```bash
systemctl restart frps
systemctl restart frpc
systemctl restart frpc-web
```

## 文档导航

- [运维说明](./docs/operations.md)
- [Web 控制台 API](./docs/web-console-api.md)
- [排障说明](./docs/troubleshooting.md)

## 说明

这个仓库仍然是一个偏实用型脚本，不是完整的部署平台。目标是减少手工安装成本，但你仍然应该把它当成运维脚本，而不是零风险的托管服务。
