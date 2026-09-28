# 排障说明

## 查看整体状态

运行安装脚本并选择 `7) 查看当前安装状态`，或执行：

```bash
systemctl status frps
systemctl status frpc
systemctl status frpc-web
```

## Web 控制台打不开

```bash
systemctl status frpc-web
journalctl -u frpc-web -n 120 --no-pager
ss -lntp | grep 7410
```

确认：

- `/usr/local/frpc/web/frpc-web` 存在且可执行
- `frpc-web.service` 的 `ExecStart` 使用 `--listen 0.0.0.0:7410`
- 防火墙允许受信客户端访问 TCP 7410
- 端口没有被其他程序占用

## 控制台提示未发现 frpc

```bash
systemctl cat frpc
systemctl show frpc.service --property=ExecStart --value
ls -l /usr/local/frpc/frpc
/usr/local/frpc/frpc --version
```

非标准路径可修改 `frpc-web.service`，显式传入 `--frpc-bin` 和 `--frpc-config`。

## 配置校验失败

```bash
/usr/local/frpc/frpc verify -c /usr/local/frpc/frpc.toml
```

常见原因包括 TOML 语法错误、字段名错误、端口格式错误和引号未闭合。校验失败时 Web 控制台不会覆盖当前配置。

## 保存并启动/重启失败

```bash
systemctl status frpc
journalctl -u frpc -n 200 --no-pager
ls -l /usr/local/frpc/frpc.toml.bak.*
```

控制台会尝试恢复旧配置和原来的 enabled/active 状态。页面显示的失败信息以及 `frpc-web` 日志可以确认回滚是否完整。

## 日志无法滚动

新版日志位于页面底部独立滚动区：

- 将鼠标放在黑色日志区域内滚动
- 移动端切换到“日志”页签
- 使用 PageUp/PageDown 或触摸滑动
- 向上滚动后“自动跟随”会暂停
- 点击“跳到最新”恢复自动跟随

如果页面仍显示旧弹窗，通常是浏览器缓存或服务器仍运行旧版 Python 控制台。检查：

```bash
systemctl cat frpc-web
readlink -f /proc/$(systemctl show -p MainPID --value frpc-web)/exe
```

## Release 下载或校验失败

检查 GitHub API、Release 下载地址和 DNS。确需代理时设置 `FRP_GITHUB_ACCEL_PREFIX`，且必须使用 HTTPS。脚本要求 Release 同时提供：

- `frpc-web-linux-amd64`
- `frpc-web-linux-arm64`
- `frpc-web-linux-arm`
- `frpc-web-linux-386`
- `SHA256SUMS`

缺少 checksum 或校验不一致时会拒绝安装。
