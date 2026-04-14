#!/usr/bin/env bash

set -euo pipefail

readonly FRP_REPO_API="https://api.github.com/repos/fatedier/frp/releases/latest"
readonly GITHUB_ACCEL_PREFIX="http://154.17.224.29/rproxy?url="
readonly FRPS_DIR="/usr/local/frps"
readonly FRPC_DIR="/usr/local/frpc"
readonly FRPC_WEB_DIR="/usr/local/frpc/web"
readonly FRPC_WEB_CONFIG="/usr/local/frpc/web/panel.json"
readonly FRPS_SERVICE="/etc/systemd/system/frps.service"
readonly FRPC_SERVICE="/etc/systemd/system/frpc.service"
readonly FRPC_WEB_SERVICE="/etc/systemd/system/frpc-web.service"

TEMP_DIR=""

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}

trap cleanup EXIT

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 用户运行此脚本。"
    exit 1
  fi
}

check_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "未检测到 systemd，无法创建系统服务。"
    exit 1
  fi
}

install_dependencies() {
  local packages=(curl jq tar python3)
  local missing=()

  for pkg in "${packages[@]}"; do
    if ! command -v "${pkg}" >/dev/null 2>&1; then
      missing+=("${pkg}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "正在安装依赖: ${missing[*]}"
    apt-get update
    apt-get install -y "${missing[@]}"
  fi
}

detect_arch() {
  local machine
  machine="$(uname -m)"

  case "${machine}" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    armv7l|armv7)
      echo "arm"
      ;;
    i386|i686)
      echo "386"
      ;;
    *)
      echo "暂不支持的架构: ${machine}"
      exit 1
      ;;
  esac
}

random_token() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-24
}

confirm() {
  local prompt="${1}"
  local answer

  read -r -p "${prompt} [y/N]: " answer
  [[ "${answer}" =~ ^[Yy]$ ]]
}

confirm_default_yes() {
  local prompt="${1}"
  local answer

  read -r -p "${prompt} [Y/n]: " answer
  [[ -z "${answer}" || "${answer}" =~ ^[Yy]$ ]]
}

prompt_non_empty() {
  local prompt="${1}"
  local value=""

  while [[ -z "${value}" ]]; do
    read -r -p "${prompt}: " value
    if [[ -z "${value}" ]]; then
      echo "输入不能为空，请重新输入。"
    fi
  done

  printf '%s\n' "${value}"
}

prompt_with_default() {
  local prompt="${1}"
  local default_value="${2}"
  local value

  read -r -p "${prompt} [默认: ${default_value}]: " value
  if [[ -z "${value}" ]]; then
    value="${default_value}"
  fi

  printf '%s\n' "${value}"
}

backup_file() {
  local file_path="${1}"

  if [[ -f "${file_path}" ]]; then
    local backup_path="${file_path}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${file_path}" "${backup_path}"
    echo "已备份: ${backup_path}"
  fi
}

fetch_release_info() {
  local api_url
  api_url="$(build_accel_url "${FRP_REPO_API}")"

  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${api_url}"
}

build_accel_url() {
  local raw_url="${1}"
  local encoded_url

  if [[ -z "${GITHUB_ACCEL_PREFIX}" ]]; then
    printf '%s\n' "${raw_url}"
    return
  fi

  encoded_url="$(jq -nr --arg url "${raw_url}" '$url|@uri')"
  printf '%s%s\n' "${GITHUB_ACCEL_PREFIX}" "${encoded_url}"
}

download_and_install_binary() {
  local app_name="${1}"
  local install_dir="${2}"
  local arch="${3}"
  local release_json tag_name asset_name download_url extract_dir

  echo "正在获取 frp 最新版本信息..."
  release_json="$(fetch_release_info)"
  tag_name="$(jq -r '.tag_name' <<<"${release_json}")"

  if [[ -z "${tag_name}" || "${tag_name}" == "null" ]]; then
    echo "获取 frp 版本失败。"
    exit 1
  fi

  asset_name="frp_${tag_name#v}_linux_${arch}.tar.gz"
  download_url="$(jq -r --arg name "${asset_name}" '.assets[] | select(.name == $name) | .browser_download_url' <<<"${release_json}")"

  if [[ -z "${download_url}" || "${download_url}" == "null" ]]; then
    echo "未找到当前架构对应的安装包: ${asset_name}"
    exit 1
  fi

  TEMP_DIR="$(mktemp -d)"

  echo "正在下载 ${asset_name} ..."
  curl -fL "$(build_accel_url "${download_url}")" -o "${TEMP_DIR}/${asset_name}"

  tar -xzf "${TEMP_DIR}/${asset_name}" -C "${TEMP_DIR}"
  extract_dir="${TEMP_DIR}/frp_${tag_name#v}_linux_${arch}"

  if [[ ! -f "${extract_dir}/${app_name}" ]]; then
    echo "安装包中未找到 ${app_name} 可执行文件。"
    exit 1
  fi

  mkdir -p "${install_dir}"
  install -m 755 "${extract_dir}/${app_name}" "${install_dir}/${app_name}"

  if [[ -f "${extract_dir}/LICENSE" ]]; then
    install -m 644 "${extract_dir}/LICENSE" "${install_dir}/LICENSE"
  fi

  echo "已安装 ${app_name} ${tag_name} 到 ${install_dir}"
}

write_frps_config() {
  local config_path="${FRPS_DIR}/frps.toml"
  local bind_port token dashboard_port dashboard_user dashboard_password enable_dashboard

  if [[ -f "${config_path}" ]] && ! confirm "检测到已存在 ${config_path}，是否覆盖"; then
    echo "保留现有服务端配置。"
    return
  fi

  backup_file "${config_path}"

  bind_port="$(prompt_with_default "请输入 frps 监听端口" "7000")"
  token="$(prompt_with_default "请输入 frps 认证 token" "$(random_token)")"
  dashboard_port=""
  dashboard_user=""
  dashboard_password=""
  enable_dashboard="n"

  if confirm "是否启用 frps Dashboard"; then
    enable_dashboard="y"
    dashboard_port="$(prompt_with_default "请输入 Dashboard 端口" "7500")"
    dashboard_user="$(prompt_with_default "请输入 Dashboard 用户名" "admin")"
    dashboard_password="$(prompt_with_default "请输入 Dashboard 密码" "$(random_token)")"
  fi

  cat >"${config_path}" <<EOF
bindPort = ${bind_port}

auth.method = "token"
auth.token = "${token}"
EOF

  if [[ "${enable_dashboard}" == "y" ]]; then
    cat >>"${config_path}" <<EOF

webServer.addr = "0.0.0.0"
webServer.port = ${dashboard_port}
webServer.user = "${dashboard_user}"
webServer.password = "${dashboard_password}"
EOF
  fi

  chmod 600 "${config_path}"
  echo "已生成服务端配置: ${config_path}"
}

write_frpc_config() {
  local config_path="${FRPC_DIR}/frpc.toml"
  local server_addr server_port token proxy_name local_ip local_port remote_port

  if [[ -f "${config_path}" ]] && ! confirm "检测到已存在 ${config_path}，是否覆盖"; then
    echo "保留现有客户端配置。"
    return
  fi

  backup_file "${config_path}"

  server_addr="$(prompt_non_empty "请输入 frps 服务端地址或域名")"
  server_port="$(prompt_with_default "请输入 frps 服务端端口" "7000")"
  token="$(prompt_non_empty "请输入 frps 对应的认证 token")"
  proxy_name="$(prompt_with_default "请输入代理名称" "tcp_proxy")"
  local_ip="$(prompt_with_default "请输入本地服务 IP" "127.0.0.1")"
  local_port="$(prompt_with_default "请输入本地服务端口" "22")"
  remote_port="$(prompt_with_default "请输入映射到 frps 的远程端口" "6000")"

  cat >"${config_path}" <<EOF
serverAddr = "${server_addr}"
serverPort = ${server_port}

auth.method = "token"
auth.token = "${token}"
EOF

  cat >>"${config_path}" <<EOF

[[proxies]]
name = "${proxy_name}"
type = "tcp"
localIP = "${local_ip}"
localPort = ${local_port}
remotePort = ${remote_port}
EOF

  chmod 600 "${config_path}"
  echo "已生成客户端配置: ${config_path}"
}

write_frps_service() {
  cat >"${FRPS_SERVICE}" <<EOF
[Unit]
Description=frp server service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${FRPS_DIR}
ExecStart=${FRPS_DIR}/frps -c ${FRPS_DIR}/frps.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_frpc_service() {
  cat >"${FRPC_SERVICE}" <<EOF
[Unit]
Description=frp client service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${FRPC_DIR}
ExecStart=${FRPC_DIR}/frpc -c ${FRPC_DIR}/frpc.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_frpc_web_server() {
  mkdir -p "${FRPC_WEB_DIR}"

  cat >"${FRPC_WEB_DIR}/frpc_web.py" <<'EOF'
#!/usr/bin/env python3

import json
import os
import subprocess
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

BASE_DIR = Path("/usr/local/frpc")
WEB_DIR = BASE_DIR / "web"
PANEL_CONFIG_PATH = WEB_DIR / "panel.json"
FRPC_CONFIG_PATH = BASE_DIR / "frpc.toml"
FRPC_BIN = BASE_DIR / "frpc"
HTML_PATH = WEB_DIR / "index.html"
SERVICE_NAME = "frpc.service"


def load_panel_config() -> dict:
    with PANEL_CONFIG_PATH.open("r", encoding="utf-8") as file_obj:
        return json.load(file_obj)


def run_command(command: list[str]) -> tuple[int, str]:
    result = subprocess.run(command, capture_output=True, text=True)
    output = (result.stdout or "") + (result.stderr or "")
    return result.returncode, output.strip()


def service_status() -> dict:
    active_code, active_output = run_command(["systemctl", "is-active", SERVICE_NAME])
    enabled_code, enabled_output = run_command(["systemctl", "is-enabled", SERVICE_NAME])
    version_code, version_output = run_command([str(FRPC_BIN), "--version"])

    status = {
        "service": SERVICE_NAME,
        "active": active_output if active_code == 0 else "inactive",
        "enabled": enabled_output if enabled_code == 0 else "disabled",
        "version": version_output if version_code == 0 else "unknown",
        "config_exists": FRPC_CONFIG_PATH.exists(),
        "config_mtime": int(FRPC_CONFIG_PATH.stat().st_mtime) if FRPC_CONFIG_PATH.exists() else None,
    }
    return status


def read_config_text() -> str:
    if not FRPC_CONFIG_PATH.exists():
        return ""
    return FRPC_CONFIG_PATH.read_text(encoding="utf-8")


def write_config_text(content: str) -> None:
    if FRPC_CONFIG_PATH.exists():
        backup_path = FRPC_CONFIG_PATH.with_suffix(f".toml.bak.{time.strftime('%Y%m%d%H%M%S')}")
        backup_path.write_text(FRPC_CONFIG_PATH.read_text(encoding="utf-8"), encoding="utf-8")
    FRPC_CONFIG_PATH.write_text(content, encoding="utf-8")
    os.chmod(FRPC_CONFIG_PATH, 0o600)


def verify_config(content: str) -> tuple[int, str]:
    with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False, encoding="utf-8") as tmp_file:
        tmp_file.write(content)
        tmp_path = tmp_file.name
    try:
        return run_command([str(FRPC_BIN), "verify", "-c", tmp_path])
    finally:
        try:
            os.remove(tmp_path)
        except FileNotFoundError:
            pass


def service_action(action: str) -> tuple[int, str]:
    return run_command(["systemctl", action, SERVICE_NAME])


def read_logs() -> str:
    _, output = run_command(["journalctl", "-u", SERVICE_NAME, "-n", "120", "--no-pager"])
    return output


class Handler(BaseHTTPRequestHandler):
    server_version = "frpc-web/1.0"

    def _send_json(self, data: dict, status: int = 200) -> None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, content: str, status: int = 200, content_type: str = "text/html; charset=utf-8") -> None:
        body = content.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
        return json.loads(raw_body or "{}")

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/":
            self._send_text(HTML_PATH.read_text(encoding="utf-8"))
            return
        if path == "/api/status":
            self._send_json({"ok": True, "data": service_status()})
            return
        if path == "/api/config":
            self._send_json({"ok": True, "data": {"content": read_config_text()}})
            return
        if path == "/api/logs":
            self._send_json({"ok": True, "data": {"logs": read_logs()}})
            return
        self._send_json({"ok": False, "message": "Not Found"}, 404)

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        try:
            payload = self._read_json_body()
        except json.JSONDecodeError:
            self._send_json({"ok": False, "message": "请求体不是合法 JSON"}, 400)
            return

        if path == "/api/verify":
            content = payload.get("content", "")
            code, output = verify_config(content)
            self._send_json({"ok": code == 0, "message": output or ("配置校验通过" if code == 0 else "配置校验失败")}, 200 if code == 0 else 400)
            return

        if path == "/api/config":
            content = payload.get("content", "")
            restart = bool(payload.get("restart", False))
            code, output = verify_config(content)
            if code != 0:
                self._send_json({"ok": False, "message": output or "配置校验失败"}, 400)
                return

            write_config_text(content)
            if restart:
                action_code, action_output = service_action("restart")
                if action_code != 0:
                    self._send_json({"ok": False, "message": action_output or "frpc 重启失败"}, 500)
                    return
            self._send_json({"ok": True, "message": "配置已保存" + ("，frpc 已重启" if restart else "")})
            return

        if path == "/api/service":
            action = payload.get("action", "")
            if action not in {"start", "stop", "restart"}:
                self._send_json({"ok": False, "message": "不支持的服务动作"}, 400)
                return
            code, output = service_action(action)
            self._send_json({"ok": code == 0, "message": output or f"frpc 已执行 {action}"}, 200 if code == 0 else 500)
            return

        self._send_json({"ok": False, "message": "Not Found"}, 404)


def main() -> None:
    cfg = load_panel_config()
    server = ThreadingHTTPServer((cfg["host"], int(cfg["port"])), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
EOF

  cat >"${FRPC_WEB_DIR}/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>frpc 控制台</title>
  <style>
    :root {
      --bg: #f3efe6;
      --panel: rgba(255, 252, 246, 0.9);
      --line: #d8ccb4;
      --text: #1e1b16;
      --muted: #6a6256;
      --accent: #0f766e;
      --accent-2: #b45309;
      --danger: #b91c1c;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      color: var(--text);
      background:
        radial-gradient(circle at top left, rgba(15,118,110,0.14), transparent 36%),
        radial-gradient(circle at right, rgba(180,83,9,0.12), transparent 28%),
        linear-gradient(180deg, #f8f4ec 0%, var(--bg) 100%);
      font-family: "Noto Sans SC", "PingFang SC", "Microsoft YaHei", sans-serif;
    }
    .wrap {
      width: min(1200px, calc(100% - 32px));
      margin: 24px auto 40px;
    }
    .hero {
      display: grid;
      grid-template-columns: 1.3fr 0.7fr;
      gap: 16px;
      margin-bottom: 16px;
    }
    .card {
      background: var(--panel);
      border: 1px solid rgba(216,204,180,0.9);
      border-radius: 22px;
      box-shadow: 0 18px 40px rgba(49, 35, 20, 0.08);
      backdrop-filter: blur(10px);
    }
    .hero-main {
      padding: 24px;
    }
    h1 {
      margin: 0 0 8px;
      font-size: 34px;
      letter-spacing: 0.02em;
    }
    .sub {
      margin: 0;
      color: var(--muted);
      line-height: 1.6;
    }
    .meta {
      padding: 24px;
      display: grid;
      gap: 14px;
      align-content: center;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      border-radius: 999px;
      padding: 6px 12px;
      background: rgba(15,118,110,0.1);
      color: var(--accent);
      font-size: 13px;
      font-weight: 700;
    }
    .grid {
      display: grid;
      grid-template-columns: 1fr 360px;
      gap: 16px;
    }
    .section {
      padding: 18px;
    }
    .section h2 {
      margin: 0 0 12px;
      font-size: 18px;
    }
    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-bottom: 12px;
    }
    button {
      border: 0;
      border-radius: 12px;
      padding: 10px 14px;
      font-size: 14px;
      font-weight: 700;
      cursor: pointer;
      background: #efe4d2;
      color: var(--text);
      transition: transform .15s ease, opacity .15s ease;
    }
    button:hover { transform: translateY(-1px); }
    button.primary { background: var(--accent); color: #fff; }
    button.warn { background: var(--accent-2); color: #fff; }
    button.danger { background: var(--danger); color: #fff; }
    textarea, pre {
      width: 100%;
      border-radius: 16px;
      border: 1px solid var(--line);
      background: rgba(255,255,255,0.7);
      color: var(--text);
      font-family: "JetBrains Mono", "Consolas", monospace;
      font-size: 13px;
      line-height: 1.6;
    }
    textarea {
      min-height: 520px;
      padding: 16px;
      resize: vertical;
    }
    pre {
      min-height: 240px;
      margin: 0;
      padding: 16px;
      overflow: auto;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .status-list {
      display: grid;
      gap: 12px;
    }
    .item {
      padding: 14px;
      border-radius: 16px;
      border: 1px solid var(--line);
      background: rgba(255,255,255,0.66);
    }
    .item strong {
      display: block;
      margin-bottom: 6px;
      font-size: 13px;
      color: var(--muted);
      font-weight: 600;
    }
    .value {
      font-size: 15px;
      font-weight: 700;
      word-break: break-all;
    }
    .result {
      margin-top: 12px;
      padding: 12px 14px;
      border-radius: 14px;
      background: rgba(15,118,110,0.08);
      font-size: 14px;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .foot {
      margin-top: 16px;
      color: var(--muted);
      font-size: 13px;
      text-align: center;
    }
    .log-tip {
      margin: 0;
      color: var(--muted);
      font-size: 14px;
      line-height: 1.7;
    }
    .modal {
      position: fixed;
      inset: 0;
      display: none;
      align-items: center;
      justify-content: center;
      padding: 18px;
      background: rgba(30, 27, 22, 0.42);
      backdrop-filter: blur(6px);
      z-index: 999;
    }
    .modal.open {
      display: flex;
    }
    .modal-panel {
      width: min(860px, 100%);
      height: min(560px, calc(100vh - 36px));
      display: grid;
      grid-template-rows: auto 1fr;
      background: rgba(255, 252, 246, 0.98);
      border: 1px solid rgba(216,204,180,0.95);
      border-radius: 24px;
      box-shadow: 0 28px 70px rgba(49, 35, 20, 0.18);
      overflow: hidden;
    }
    .modal-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      padding: 18px 20px;
      border-bottom: 1px solid var(--line);
      background: linear-gradient(180deg, rgba(255,255,255,0.92), rgba(248,244,236,0.88));
    }
    .modal-head h3 {
      margin: 0;
      font-size: 18px;
    }
    .modal-actions {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
    }
    .close-btn {
      background: rgba(30, 27, 22, 0.08);
      color: var(--text);
    }
    .modal-body {
      padding: 18px 20px 20px;
      overflow: hidden;
    }
    .modal-body pre {
      height: 100%;
      min-height: 0;
      margin: 0;
      overflow: auto;
    }
    @media (max-width: 980px) {
      .hero, .grid {
        grid-template-columns: 1fr;
      }
      textarea {
        min-height: 380px;
      }
      .modal-panel {
        height: min(620px, calc(100vh - 24px));
      }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="hero">
      <section class="card hero-main">
        <span class="badge">frpc Web 控制台</span>
        <h1>管理配置、状态与日志</h1>
        <p class="sub">这个面板用于管理本机的 <code>frpc.service</code>。你可以直接编辑 <code>frpc.toml</code>，先校验再保存，必要时一键重启服务。</p>
      </section>
      <aside class="card meta">
        <div>
          <strong>服务名</strong>
          <div class="value">frpc.service</div>
        </div>
        <div>
          <strong>配置文件</strong>
          <div class="value">/usr/local/frpc/frpc.toml</div>
        </div>
        <div>
          <strong>控制台说明</strong>
          <div class="value">直接访问 IP 和端口即可进入</div>
        </div>
      </aside>
    </div>

    <div class="grid">
      <section class="card section">
        <h2>配置编辑</h2>
        <div class="toolbar">
          <button onclick="refreshConfig()">刷新配置</button>
          <button onclick="verifyConfig()">校验配置</button>
          <button class="warn" onclick="saveConfig(false)">保存配置</button>
          <button class="primary" onclick="saveConfig(true)">保存并重启</button>
        </div>
        <textarea id="configBox" spellcheck="false"></textarea>
        <div id="resultBox" class="result">等待操作。</div>
      </section>

      <section class="card section">
        <h2>服务状态</h2>
        <div class="toolbar">
          <button onclick="refreshStatus()">刷新状态</button>
          <button class="primary" onclick="serviceAction('start')">启动</button>
          <button class="warn" onclick="serviceAction('restart')">重启</button>
          <button class="danger" onclick="serviceAction('stop')">停止</button>
        </div>
        <div class="status-list">
          <div class="item"><strong>运行状态</strong><div id="active" class="value">-</div></div>
          <div class="item"><strong>开机自启</strong><div id="enabled" class="value">-</div></div>
          <div class="item"><strong>frpc 版本</strong><div id="version" class="value">-</div></div>
          <div class="item"><strong>配置文件时间</strong><div id="mtime" class="value">-</div></div>
        </div>
        <h2 style="margin-top:18px;">最近日志</h2>
        <div class="toolbar">
          <button class="warn" onclick="openLogsModal()">查看日志</button>
        </div>
        <p class="log-tip">日志改为弹出窗口查看，窗口尺寸固定，内容区域支持滚动，避免主界面被长日志撑开。</p>
      </section>
    </div>

    <div class="foot">建议把 Web 控制台放在防火墙或内网访问范围内使用。</div>
  </div>

  <div id="logsModal" class="modal" onclick="handleModalBackdrop(event)">
    <div class="modal-panel">
      <div class="modal-head">
        <h3>frpc 最近日志</h3>
        <div class="modal-actions">
          <button onclick="refreshLogs()">刷新日志</button>
          <button class="close-btn" onclick="closeLogsModal()">关闭</button>
        </div>
      </div>
      <div class="modal-body">
        <pre id="logsBox">正在读取日志...</pre>
      </div>
    </div>
  </div>

  <script>
    async function request(url, options = {}) {
      const response = await fetch(url, {
        headers: { 'Content-Type': 'application/json' },
        ...options
      });
      const data = await response.json().catch(() => ({ ok: false, message: '接口返回异常' }));
      if (!response.ok || data.ok === false) {
        throw new Error(data.message || '请求失败');
      }
      return data;
    }

    function setResult(message, isError = false) {
      const box = document.getElementById('resultBox');
      box.textContent = message;
      box.style.background = isError ? 'rgba(185,28,28,0.10)' : 'rgba(15,118,110,0.08)';
      box.style.color = isError ? '#991b1b' : '#134e4a';
    }

    function formatTime(ts) {
      if (!ts) return '-';
      return new Date(ts * 1000).toLocaleString('zh-CN', { hour12: false });
    }

    async function refreshStatus() {
      const data = await request('/api/status');
      const status = data.data;
      document.getElementById('active').textContent = status.active;
      document.getElementById('enabled').textContent = status.enabled;
      document.getElementById('version').textContent = status.version;
      document.getElementById('mtime').textContent = formatTime(status.config_mtime);
    }

    async function refreshConfig() {
      const data = await request('/api/config');
      document.getElementById('configBox').value = data.data.content || '';
      setResult('配置已刷新。');
    }

    async function refreshLogs() {
      const data = await request('/api/logs');
      document.getElementById('logsBox').textContent = data.data.logs || '暂无日志。';
    }

    async function openLogsModal() {
      document.getElementById('logsModal').classList.add('open');
      document.body.style.overflow = 'hidden';
      await refreshLogs();
    }

    function closeLogsModal() {
      document.getElementById('logsModal').classList.remove('open');
      document.body.style.overflow = '';
    }

    function handleModalBackdrop(event) {
      if (event.target.id === 'logsModal') {
        closeLogsModal();
      }
    }

    async function verifyConfig() {
      try {
        const content = document.getElementById('configBox').value;
        const data = await request('/api/verify', {
          method: 'POST',
          body: JSON.stringify({ content })
        });
        setResult(data.message || '配置校验通过。');
      } catch (error) {
        setResult(error.message, true);
      }
    }

    async function saveConfig(restart) {
      try {
        const content = document.getElementById('configBox').value;
        const data = await request('/api/config', {
          method: 'POST',
          body: JSON.stringify({ content, restart })
        });
        setResult(data.message || '配置已保存。');
        await refreshStatus();
        await refreshLogs();
      } catch (error) {
        setResult(error.message, true);
      }
    }

    async function serviceAction(action) {
      try {
        const data = await request('/api/service', {
          method: 'POST',
          body: JSON.stringify({ action })
        });
        setResult(data.message || ('已执行 ' + action));
        await refreshStatus();
        await refreshLogs();
      } catch (error) {
        setResult(error.message, true);
      }
    }

    async function boot() {
      try {
        await Promise.all([refreshStatus(), refreshConfig()]);
      } catch (error) {
        setResult(error.message, true);
      }
    }

    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        closeLogsModal();
      }
    });

    boot();
  </script>
</body>
</html>
EOF

  chmod 755 "${FRPC_WEB_DIR}/frpc_web.py"
  chmod 644 "${FRPC_WEB_DIR}/index.html"
}

write_frpc_web_config() {
  local panel_host="${1}"
  local panel_port="${2}"

  mkdir -p "${FRPC_WEB_DIR}"

  if [[ -f "${FRPC_WEB_CONFIG}" ]]; then
    backup_file "${FRPC_WEB_CONFIG}"
  fi

  cat >"${FRPC_WEB_CONFIG}" <<EOF
{
  "host": "${panel_host}",
  "port": ${panel_port}
}
EOF

  chmod 600 "${FRPC_WEB_CONFIG}"
}

write_frpc_web_service() {
  cat >"${FRPC_WEB_SERVICE}" <<EOF
[Unit]
Description=frpc web console service
After=network-online.target frpc.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${FRPC_WEB_DIR}
ExecStart=/usr/bin/python3 ${FRPC_WEB_DIR}/frpc_web.py
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

setup_frpc_web_panel() {
  local panel_host panel_port rewrite_config="y"

  panel_host="0.0.0.0"
  panel_port="7410"

  if [[ -f "${FRPC_WEB_CONFIG}" ]] && ! confirm "检测到已存在 frpc Web 控制台配置，是否覆盖"; then
    rewrite_config="n"
  else
    panel_host="$(prompt_with_default "请输入 frpc Web 控制台监听地址" "${panel_host}")"
    panel_port="$(prompt_with_default "请输入 frpc Web 控制台端口" "${panel_port}")"
  fi

  write_frpc_web_server

  if [[ "${rewrite_config}" == "y" ]]; then
    write_frpc_web_config "${panel_host}" "${panel_port}"
  fi

  backup_file "${FRPC_WEB_SERVICE}"
  write_frpc_web_service
  enable_service "frpc-web.service"

  panel_host="$(jq -r '.host' "${FRPC_WEB_CONFIG}")"
  panel_port="$(jq -r '.port' "${FRPC_WEB_CONFIG}")"

  echo "frpc Web 控制台已部署。"
  echo "配置文件: ${FRPC_WEB_CONFIG}"
  echo "访问地址: http://${panel_host}:${panel_port}"
  echo "服务管理: systemctl status|restart|stop frpc-web"
}

enable_service() {
  local service_name="${1}"

  systemctl daemon-reload
  systemctl enable "${service_name}"

  if ! systemctl restart "${service_name}"; then
    echo "警告: ${service_name} 启动失败，请检查配置或网络连通性。"
  fi

  systemctl --no-pager --full status "${service_name}" || true
}

is_service_registered() {
  local service_name="${1}"
  systemctl list-unit-files | grep -q "^${service_name}[[:space:]]"
}

disable_service_if_exists() {
  local service_name="${1}"

  if is_service_registered "${service_name}"; then
    systemctl stop "${service_name}" || true
    systemctl disable "${service_name}" || true
  fi
}

service_state() {
  local service_name="${1}"

  if ! is_service_registered "${service_name}"; then
    echo "未注册"
    return
  fi

  systemctl is-active "${service_name}" 2>/dev/null || echo "inactive"
}

service_enabled_state() {
  local service_name="${1}"

  if ! is_service_registered "${service_name}"; then
    echo "未注册"
    return
  fi

  systemctl is-enabled "${service_name}" 2>/dev/null || echo "disabled"
}

install_frps() {
  local arch
  arch="$(detect_arch)"

  if is_service_registered "frps.service"; then
    systemctl stop frps.service || true
  fi

  mkdir -p "${FRPS_DIR}"
  backup_file "${FRPS_SERVICE}"

  download_and_install_binary "frps" "${FRPS_DIR}" "${arch}"
  write_frps_config
  write_frps_service
  enable_service "frps.service"

  echo
  echo "frps 安装完成。"
  echo "配置文件: ${FRPS_DIR}/frps.toml"
  echo "服务管理: systemctl status|restart|stop frps"
}

install_frpc() {
  local arch
  arch="$(detect_arch)"

  if is_service_registered "frpc.service"; then
    systemctl stop frpc.service || true
  fi
  if is_service_registered "frpc-web.service"; then
    systemctl stop frpc-web.service || true
  fi

  mkdir -p "${FRPC_DIR}"
  backup_file "${FRPC_SERVICE}"
  backup_file "${FRPC_WEB_SERVICE}"

  download_and_install_binary "frpc" "${FRPC_DIR}" "${arch}"
  write_frpc_config
  echo "正在校验 frpc 配置..."
  "${FRPC_DIR}/frpc" verify -c "${FRPC_DIR}/frpc.toml"
  write_frpc_service
  enable_service "frpc.service"

  if confirm_default_yes "是否部署 frpc Web 控制台"; then
    setup_frpc_web_panel
  fi

  echo
  echo "frpc 安装完成。"
  echo "配置文件: ${FRPC_DIR}/frpc.toml"
  echo "服务管理: systemctl status|restart|stop frpc"
}

update_frps() {
  local arch
  arch="$(detect_arch)"

  if [[ ! -x "${FRPS_DIR}/frps" ]]; then
    echo "未检测到已安装的 frps: ${FRPS_DIR}/frps"
    echo "请先执行安装。"
    exit 1
  fi

  if is_service_registered "frps.service"; then
    systemctl stop frps.service || true
  fi

  download_and_install_binary "frps" "${FRPS_DIR}" "${arch}"

  if [[ ! -f "${FRPS_SERVICE}" ]]; then
    echo "未检测到 frps.service，正在重新生成服务文件。"
    write_frps_service
  fi

  enable_service "frps.service"

  echo
  echo "frps 更新完成。"
  echo "配置文件保持不变: ${FRPS_DIR}/frps.toml"
  echo "服务管理: systemctl status|restart|stop frps"
}

update_frpc() {
  local arch
  arch="$(detect_arch)"

  if [[ ! -x "${FRPC_DIR}/frpc" ]]; then
    echo "未检测到已安装的 frpc: ${FRPC_DIR}/frpc"
    echo "请先执行安装。"
    exit 1
  fi

  if is_service_registered "frpc.service"; then
    systemctl stop frpc.service || true
  fi
  if is_service_registered "frpc-web.service"; then
    systemctl stop frpc-web.service || true
  fi

  download_and_install_binary "frpc" "${FRPC_DIR}" "${arch}"

  if [[ -f "${FRPC_DIR}/frpc.toml" ]]; then
    echo "正在校验 frpc 配置..."
    "${FRPC_DIR}/frpc" verify -c "${FRPC_DIR}/frpc.toml"
  else
    echo "未找到客户端配置文件: ${FRPC_DIR}/frpc.toml"
    echo "请先补充配置后再启动服务。"
  fi

  if [[ ! -f "${FRPC_SERVICE}" ]]; then
    echo "未检测到 frpc.service，正在重新生成服务文件。"
    write_frpc_service
  fi

  enable_service "frpc.service"

  if [[ -f "${FRPC_WEB_CONFIG}" || -f "${FRPC_WEB_SERVICE}" ]]; then
    echo "正在刷新 frpc Web 控制台..."
    write_frpc_web_server
    if [[ ! -f "${FRPC_WEB_SERVICE}" ]]; then
      write_frpc_web_service
    fi
    enable_service "frpc-web.service"
  fi

  echo
  echo "frpc 更新完成。"
  echo "配置文件保持不变: ${FRPC_DIR}/frpc.toml"
  echo "服务管理: systemctl status|restart|stop frpc"
}

uninstall_frps() {
  if ! confirm "确认卸载 frps 服务端并删除 ${FRPS_DIR}"; then
    echo "已取消卸载。"
    exit 0
  fi

  disable_service_if_exists "frps.service"

  rm -f "${FRPS_SERVICE}"
  rm -rf "${FRPS_DIR}"

  systemctl daemon-reload

  echo
  echo "frps 已卸载完成。"
}

uninstall_frpc() {
  if ! confirm "确认卸载 frpc 客户端及 Web 控制台并删除 ${FRPC_DIR}"; then
    echo "已取消卸载。"
    exit 0
  fi

  disable_service_if_exists "frpc-web.service"
  disable_service_if_exists "frpc.service"

  rm -f "${FRPC_WEB_SERVICE}"
  rm -f "${FRPC_SERVICE}"
  rm -rf "${FRPC_DIR}"

  systemctl daemon-reload

  echo
  echo "frpc 与 Web 控制台已卸载完成。"
}

show_install_status() {
  local frps_version="未安装"
  local frpc_version="未安装"

  if [[ -x "${FRPS_DIR}/frps" ]]; then
    frps_version="$("${FRPS_DIR}/frps" --version 2>/dev/null || echo "未知")"
  fi

  if [[ -x "${FRPC_DIR}/frpc" ]]; then
    frpc_version="$("${FRPC_DIR}/frpc" --version 2>/dev/null || echo "未知")"
  fi

  echo
  echo "===== frps 服务端状态 ====="
  echo "安装目录: ${FRPS_DIR}"
  echo "二进制: $([[ -x "${FRPS_DIR}/frps" ]] && echo 已安装 || echo 未安装)"
  echo "版本: ${frps_version}"
  echo "配置文件: $([[ -f "${FRPS_DIR}/frps.toml" ]] && echo 存在 || echo 不存在)"
  echo "systemd 服务: $(service_state "frps.service")"
  echo "开机自启: $(service_enabled_state "frps.service")"

  echo
  echo "===== frpc 客户端状态 ====="
  echo "安装目录: ${FRPC_DIR}"
  echo "二进制: $([[ -x "${FRPC_DIR}/frpc" ]] && echo 已安装 || echo 未安装)"
  echo "版本: ${frpc_version}"
  echo "配置文件: $([[ -f "${FRPC_DIR}/frpc.toml" ]] && echo 存在 || echo 不存在)"
  echo "systemd 服务: $(service_state "frpc.service")"
  echo "开机自启: $(service_enabled_state "frpc.service")"

  echo
  echo "===== frpc Web 控制台状态 ====="
  echo "目录: ${FRPC_WEB_DIR}"
  echo "程序文件: $([[ -f "${FRPC_WEB_DIR}/frpc_web.py" ]] && echo 存在 || echo 不存在)"
  echo "页面文件: $([[ -f "${FRPC_WEB_DIR}/index.html" ]] && echo 存在 || echo 不存在)"
  echo "控制台配置: $([[ -f "${FRPC_WEB_CONFIG}" ]] && echo 存在 || echo 不存在)"
  echo "systemd 服务: $(service_state "frpc-web.service")"
  echo "开机自启: $(service_enabled_state "frpc-web.service")"

  if [[ -f "${FRPC_WEB_CONFIG}" ]]; then
    echo "访问地址: http://$(jq -r '.host' "${FRPC_WEB_CONFIG}")":"$(jq -r '.port' "${FRPC_WEB_CONFIG}")"
  fi
}

select_mode() {
  local choice

  echo "请选择安装模式:"
  echo "1) 安装 frps 服务端"
  echo "2) 安装 frpc 客户端"
  echo "3) 更新 frps 服务端"
  echo "4) 更新 frpc 客户端"
  echo "5) 卸载 frps 服务端"
  echo "6) 卸载 frpc 客户端"
  echo "7) 查看当前安装状态"
  read -r -p "请输入序号 [1-7]: " choice

  case "${choice}" in
    1)
      install_frps
      ;;
    2)
      install_frpc
      ;;
    3)
      update_frps
      ;;
    4)
      update_frpc
      ;;
    5)
      uninstall_frps
      ;;
    6)
      uninstall_frpc
      ;;
    7)
      show_install_status
      ;;
    *)
      echo "无效输入，请重新运行脚本并输入 1 到 7。"
      exit 1
      ;;
  esac
}

main() {
  require_root
  check_systemd
  install_dependencies
  select_mode
}

main "$@"
