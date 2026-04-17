# 排障说明

本文档覆盖当前脚本最常见的失败场景与检查方法。

## 先看状态

优先执行：

```bash
./install_frp.sh
```

然后选择：

```text
7) 查看当前安装状态
```

再结合：

```bash
systemctl status frps
systemctl status frpc
systemctl status frpc-web
```

## 下载失败

表现：

- 获取 release 信息失败
- 下载 `tar.gz` 失败

检查：

- 目标机是否能访问 GitHub API
- 目标机是否能访问脚本中配置的加速代理
- DNS、出口网络、防火墙是否正常

说明：

- 当前脚本默认通过第三方 HTTP 代理请求 GitHub 资源
- 如果代理不可达，下载会直接失败

## 配置校验失败

表现：

- 安装或更新时提示 `verify` 失败
- Web 控制台保存时提示“配置校验失败”

检查：

```bash
/usr/local/frpc/frpc verify -c /usr/local/frpc/frpc.toml
/usr/local/frps/frps verify -c /usr/local/frps/frps.toml
```

常见原因：

- 端口不是合法数字
- TOML 语法被破坏
- 手工编辑时引号、换行或字段名有误

## 更新后服务启动失败

表现：

- 更新流程失败
- 服务没有进入 `active`

当前脚本行为：

- 会先用新版本校验现有配置
- 新版本启动失败时会自动回滚上一版二进制并尝试恢复服务

检查：

```bash
systemctl status frps
systemctl status frpc
journalctl -u frps -n 120 --no-pager
journalctl -u frpc -n 120 --no-pager
```

如果回滚后仍失败，优先检查：

- 当前配置是否本身已损坏
- 端口是否被占用
- 旧服务文件是否被手工改坏

## Web 控制台保存并重启失败

表现：

- 页面提示保存失败或重启失败

当前脚本行为：

- 会先备份旧配置
- 重启失败时自动写回上一份配置
- 然后尝试恢复 `frpc.service`

检查：

```bash
systemctl status frpc
journalctl -u frpc -n 120 --no-pager
ls -l /usr/local/frpc/*.bak.*
```

## Web 控制台打不开

检查：

```bash
systemctl status frpc-web
journalctl -u frpc-web -n 120 --no-pager
cat /usr/local/frpc/web/panel.json
```

确认：

- `panel.json` 中的 `host` / `port` 是否正确
- 端口是否被占用
- 浏览器访问的地址是否正确

## 架构不支持

表现：

- 脚本提示“暂不支持的架构”

检查：

```bash
uname -m
```

当前支持：

- `x86_64` / `amd64`
- `aarch64` / `arm64`
- `armv7l` / `armv7`
- `i386` / `i686`

## 需要手工恢复时

优先保留这些信息：

- `systemctl status` 输出
- `journalctl` 最近日志
- 当前 `frps.toml` / `frpc.toml`
- 同目录下的 `.bak.<时间戳>` 备份文件

如果是配置问题，通常最稳妥的恢复方式是：

1. 用最近的备份覆盖当前配置
2. 手工执行 `verify`
3. 再重启对应服务
