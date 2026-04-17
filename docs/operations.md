# 运维说明

本文档描述当前脚本的运行边界、安装路径、更新与回滚语义。

## 环境要求

- 操作系统：`Debian 12`
- `systemd`
- `root`
- 支持架构：`amd64`、`arm64`、`arm`、`386`
- 能访问 GitHub API，或能访问脚本内配置的加速代理

## 安装内容

### frps

- 安装目录：`/usr/local/frps`
- 二进制：`/usr/local/frps/frps`
- 配置：`/usr/local/frps/frps.toml`
- 服务：`/etc/systemd/system/frps.service`

### frpc

- 安装目录：`/usr/local/frpc`
- 二进制：`/usr/local/frpc/frpc`
- 配置：`/usr/local/frpc/frpc.toml`
- 服务：`/etc/systemd/system/frpc.service`

### frpc Web 控制台

- 目录：`/usr/local/frpc/web`
- 程序：`/usr/local/frpc/web/frpc_web.py`
- 页面：`/usr/local/frpc/web/index.html`
- 配置：`/usr/local/frpc/web/panel.json`
- 服务：`/etc/systemd/system/frpc-web.service`

## 配置生成规则

- `frps` 生成的是最小可运行配置，可选开启 Dashboard
- `frpc` 默认只生成一个 `tcp` 代理示例
- 配置文件权限会设置为 `600`
- 覆盖旧配置前会生成 `.bak.<时间戳>` 备份

## 安装语义

### 安装 frps

流程：

1. 下载新版本二进制
2. 安装到 `/usr/local/frps`
3. 生成或覆盖 `frps.toml`
4. 校验配置
5. 写入 `frps.service`
6. 启动并验证服务状态

### 安装 frpc

流程：

1. 下载新版本二进制
2. 安装到 `/usr/local/frpc`
3. 生成或覆盖 `frpc.toml`
4. 校验配置
5. 写入 `frpc.service`
6. 启动并验证服务状态
7. 如用户选择，再部署 `frpc Web 控制台`

## 更新语义

### frps / frpc 更新

更新前会：

1. 下载新版本到临时目录
2. 使用新版本二进制校验当前配置

只有校验通过后，才会：

1. 停止旧服务
2. 替换二进制
3. 重新启动服务

如果新版本启动失败：

1. 自动恢复上一版二进制
2. 尝试重新拉起旧服务

当前回滚范围：

- 会回滚 `frps` / `frpc` 二进制与 `LICENSE`
- 不会自动回滚你手工修改过的配置文件内容
- 不会回滚外部依赖或系统级环境

## Web 控制台保存语义

Web 控制台保存配置时会：

1. 先用 `frpc verify -c` 校验新配置
2. 生成旧配置备份
3. 原子写入新配置

如果选择“保存并重启”：

- `frpc` 重启成功：保留新配置
- `frpc` 重启失败：自动恢复到上一份配置，并尝试恢复服务

## 卸载语义

### 卸载 frps

会删除：

- `frps.service`
- `/usr/local/frps`

### 卸载 frpc

会删除：

- `frpc.service`
- `frpc-web.service`
- `/usr/local/frpc`

不会主动清理：

- 你手工复制到其他目录的备份文件
- 系统包管理器安装的依赖

## 安全边界

- 脚本以 `root` 运行
- 当前默认使用第三方 HTTP 加速代理下载 release 资源
- `frpc Web 控制台` 当前仍然没有内建鉴权
- 默认提示监听 `0.0.0.0:7410`

因此建议：

- 仅在受控机器上运行
- 仅在本机或受限内网中使用 Web 控制台
- 如需远程访问，请自行增加反向代理、TLS、鉴权和防火墙策略
