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
RELEASE_TAG=""
RELEASE_EXTRACT_DIR=""

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

download_release_bundle() {
  local app_name="${1}"
  local arch="${2}"
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

  RELEASE_TAG="${tag_name}"
  RELEASE_EXTRACT_DIR="${extract_dir}"
  echo "已下载 ${app_name} ${tag_name}"
}

install_release_binary() {
  local app_name="${1}"
  local install_dir="${2}"

  mkdir -p "${install_dir}"
  install -m 755 "${RELEASE_EXTRACT_DIR}/${app_name}" "${install_dir}/${app_name}"

  if [[ -f "${RELEASE_EXTRACT_DIR}/LICENSE" ]]; then
    install -m 644 "${RELEASE_EXTRACT_DIR}/LICENSE" "${install_dir}/LICENSE"
  fi

  echo "已安装 ${app_name} ${RELEASE_TAG} 到 ${install_dir}"
}

verify_config_with_binary() {
  local binary_path="${1}"
  local config_path="${2}"
  local app_name="${3}"

  if [[ ! -f "${config_path}" ]]; then
    echo "未找到 ${app_name} 配置文件: ${config_path}"
    return 1
  fi

  echo "正在校验 ${app_name} 配置..."
  "${binary_path}" verify -c "${config_path}"
}

create_runtime_backup() {
  local install_dir="${1}"
  local app_name="${2}"
  local backup_dir="${TEMP_DIR}/rollback-${app_name}"

  mkdir -p "${backup_dir}"

  if [[ -f "${install_dir}/${app_name}" ]]; then
    cp -a "${install_dir}/${app_name}" "${backup_dir}/${app_name}"
  fi
  if [[ -f "${install_dir}/LICENSE" ]]; then
    cp -a "${install_dir}/LICENSE" "${backup_dir}/LICENSE"
  fi

  printf '%s\n' "${backup_dir}"
}

restore_runtime_backup() {
  local backup_dir="${1}"
  local install_dir="${2}"
  local app_name="${3}"

  if [[ -f "${backup_dir}/${app_name}" ]]; then
    install -m 755 "${backup_dir}/${app_name}" "${install_dir}/${app_name}"
  else
    rm -f "${install_dir}/${app_name}"
  fi

  if [[ -f "${backup_dir}/LICENSE" ]]; then
    install -m 644 "${backup_dir}/LICENSE" "${install_dir}/LICENSE"
  else
    rm -f "${install_dir}/LICENSE"
  fi
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


def build_backup_path(path: Path) -> Path:
    return path.with_suffix(f"{path.suffix}.bak.{time.strftime('%Y%m%d%H%M%S')}")


def write_text_atomic(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file_obj:
            file_obj.write(content)
            file_obj.flush()
            os.fsync(file_obj.fileno())
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)


def save_config_backup(content: str) -> Path:
    backup_path = build_backup_path(FRPC_CONFIG_PATH)
    write_text_atomic(backup_path, content)
    return backup_path


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


def apply_config_change(content: str, restart: bool) -> tuple[bool, str]:
    previous_content = FRPC_CONFIG_PATH.read_text(encoding="utf-8") if FRPC_CONFIG_PATH.exists() else None

    if previous_content is not None:
        save_config_backup(previous_content)

    write_text_atomic(FRPC_CONFIG_PATH, content)

    if not restart:
        return True, "配置已保存"

    restart_code, restart_output = service_action("restart")
    if restart_code == 0:
        return True, "配置已保存，frpc 已重启"

    rollback_note = ""
    if previous_content is not None:
        write_text_atomic(FRPC_CONFIG_PATH, previous_content)
        rollback_code, rollback_output = service_action("restart")
        if rollback_code == 0:
            rollback_note = "，已回滚到上一份配置并恢复服务"
        else:
            rollback_note = "，已回滚到上一份配置，但服务恢复失败"
            if rollback_output:
                rollback_note += f": {rollback_output}"
    else:
        try:
            FRPC_CONFIG_PATH.unlink(missing_ok=True)
        except TypeError:
            if FRPC_CONFIG_PATH.exists():
                FRPC_CONFIG_PATH.unlink()
        rollback_note = "，已移除新配置文件"

    return False, (restart_output or "frpc 重启失败") + rollback_note


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

            try:
                ok, message = apply_config_change(content, restart)
            except OSError as error:
                self._send_json({"ok": False, "message": f"写入配置失败: {error}"}, 500)
                return

            self._send_json({"ok": ok, "message": message}, 200 if ok else 500)
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
      --bg: #f4f6f8;
      --bg-soft: #eef2f5;
      --surface-1: #ffffff;
      --surface-2: #f8fafc;
      --surface-3: #f1f5f9;
      --border-soft: #dde4ec;
      --border-strong: #ccd6e1;
      --text: #18212b;
      --text-muted: #5f6c7b;
      --accent: #2563eb;
      --accent-deep: #1d4ed8;
      --accent-soft: rgba(37, 99, 235, 0.12);
      --warning: #d97706;
      --warning-soft: rgba(217, 119, 6, 0.12);
      --danger: #dc2626;
      --danger-soft: rgba(220, 38, 38, 0.12);
      --success: #0f766e;
      --success-soft: rgba(15, 118, 110, 0.12);
      --shadow-soft: 0 14px 30px rgba(15, 23, 42, 0.06);
      --shadow-strong: 0 22px 48px rgba(15, 23, 42, 0.10);
      --radius-xl: 24px;
      --radius-lg: 20px;
      --radius-md: 16px;
      --radius-sm: 12px;
      --gap: 20px;
      --ease: 180ms cubic-bezier(.2,.8,.2,1);
    }
    * { box-sizing: border-box; }
    html { color-scheme: light; }
    body {
      margin: 0;
      min-height: 100vh;
      color: var(--text);
      font-family: "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
      background: linear-gradient(180deg, #f8fafc 0%, var(--bg) 36%, var(--bg-soft) 100%);
      position: relative;
      overflow-x: hidden;
    }
    .page-shell {
      position: relative;
      z-index: 1;
      width: min(1220px, calc(100% - 40px));
      margin: 32px auto 40px;
    }
    .card {
      position: relative;
      background: var(--surface-1);
      border: 1px solid var(--border-soft);
      border-radius: var(--radius-lg);
      box-shadow: var(--shadow-soft);
    }
    .workspace,
    .side-card {
      position: relative;
      z-index: 1;
    }
    .layout {
      display: grid;
      grid-template-columns: minmax(0, 1.24fr) minmax(320px, 0.76fr);
      gap: var(--gap);
      align-items: start;
    }
    .workspace,
    .side-card {
      padding: 26px;
    }
    .sidebar {
      display: grid;
      gap: var(--gap);
    }
    .section-head {
      display: flex;
      align-items: flex-end;
      justify-content: space-between;
      gap: 20px;
      margin-bottom: 24px;
      flex-wrap: wrap;
    }
    .section-copy {
      max-width: 58ch;
    }
    .section-copy.section-meta {
      flex: 0 1 280px;
      padding: 14px 16px;
      border: 1px solid var(--border-soft);
      border-radius: var(--radius-md);
      background: var(--surface-2);
    }
    .section-kicker {
      margin: 0 0 8px;
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.04em;
      color: var(--accent);
    }
    h2 {
      margin: 0;
      font-size: 34px;
      line-height: 1.12;
      letter-spacing: -0.04em;
    }
    .section-sub {
      margin: 10px 0 0;
      color: var(--text-muted);
      line-height: 1.75;
      font-size: 15px;
    }
    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 14px;
      margin-bottom: 20px;
    }
    .toolbar-group {
      display: flex;
      flex: 1 1 260px;
      gap: 12px;
      flex-wrap: wrap;
    }
    .toolbar-group.primary-group {
      justify-content: flex-end;
    }
    .section-note {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 12px;
      margin-bottom: 14px;
      flex-wrap: wrap;
    }
    .field-label {
      display: inline-flex;
      align-items: center;
      gap: 10px;
      font-size: 13px;
      font-weight: 700;
      letter-spacing: 0.04em;
      color: var(--text-muted);
    }
    .field-label::before {
      content: "";
      width: 9px;
      height: 9px;
      border-radius: 999px;
      background: rgba(37, 99, 235, 0.24);
      box-shadow: 0 0 0 5px rgba(37, 99, 235, 0.08);
    }
    .inline-status {
      margin: 0;
      font-size: 14px;
      color: var(--text-muted);
      line-height: 1.6;
    }
    .editor-shell {
      border-radius: var(--radius-md);
      border: 1px solid var(--border-strong);
      background: var(--surface-2);
      box-shadow: inset 0 1px 0 rgba(255,255,255,0.88);
      overflow: hidden;
      transition: border-color var(--ease), box-shadow var(--ease), transform var(--ease);
    }
    .editor-shell[data-state="dirty"] {
      border-color: rgba(217, 119, 6, 0.34);
      box-shadow:
        inset 0 1px 0 rgba(255,255,255,0.88),
        0 0 0 4px rgba(217, 119, 6, 0.08);
    }
    .editor-shell.is-busy {
      border-color: rgba(37, 99, 235, 0.26);
    }
    .editor-topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 14px;
      padding: 16px 18px;
      flex-wrap: wrap;
      border-bottom: 1px solid var(--border-soft);
      background: #fbfdff;
    }
    .state-pill {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      min-height: 36px;
      padding: 7px 13px;
      border-radius: 999px;
      border: 1px solid rgba(15, 118, 110, 0.18);
      background: var(--success-soft);
      color: var(--success);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.04em;
    }
    .state-pill.dirty {
      border-color: rgba(217, 119, 6, 0.18);
      background: var(--warning-soft);
      color: var(--warning);
    }
    .state-pill.error {
      border-color: rgba(220, 38, 38, 0.18);
      background: var(--danger-soft);
      color: var(--danger);
    }
    button {
      min-height: 46px;
      padding: 11px 16px;
      border: 1px solid var(--border-soft);
      border-radius: var(--radius-sm);
      background: #fff;
      color: var(--text);
      font-size: 14px;
      font-weight: 700;
      cursor: pointer;
      box-shadow: 0 6px 14px rgba(15, 23, 42, 0.04);
      transition:
        transform var(--ease),
        opacity var(--ease),
        border-color var(--ease),
        background-color var(--ease),
        box-shadow var(--ease);
    }
    button.primary {
      border-color: transparent;
      background: linear-gradient(180deg, #3775f5, var(--accent));
      color: #fff;
      box-shadow: 0 10px 20px rgba(37, 99, 235, 0.20);
    }
    button.warn {
      border-color: transparent;
      background: linear-gradient(180deg, #ea9a2f, var(--warning));
      color: #fff;
      box-shadow: 0 10px 20px rgba(217, 119, 6, 0.18);
    }
    button.danger {
      border-color: transparent;
      background: linear-gradient(180deg, #ef4444, var(--danger));
      color: #fff;
      box-shadow: 0 10px 20px rgba(220, 38, 38, 0.18);
    }
    button.close-btn {
      background: #fff;
      border-color: var(--border-soft);
      box-shadow: none;
    }
    button:disabled {
      opacity: 0.55;
      cursor: not-allowed;
      transform: none;
      box-shadow: none;
    }
    button:focus-visible,
    textarea:focus-visible,
    .modal-panel:focus-visible,
    #logsBox:focus-visible {
      outline: 3px solid rgba(37, 99, 235, 0.22);
      outline-offset: 2px;
    }
    @media (hover: hover) and (pointer: fine) {
      button:hover,
      .stat-card:hover,
      .log-card:hover {
        transform: translateY(-1px);
      }
      button:hover {
        border-color: var(--border-strong);
        box-shadow: 0 10px 20px rgba(15, 23, 42, 0.08);
      }
    }
    textarea,
    pre {
      width: 100%;
      border: 0;
      background: transparent;
      color: var(--text);
      font-family: "SFMono-Regular", "JetBrains Mono", "Consolas", monospace;
      font-size: 14px;
      line-height: 1.75;
    }
    textarea {
      display: block;
      min-height: clamp(420px, 54vh, 600px);
      padding: 20px 20px 22px;
      resize: vertical;
      outline: none;
    }
    pre {
      min-height: 260px;
      margin: 0;
      padding: 20px 22px 24px;
      overflow: auto;
      white-space: pre-wrap;
      word-break: break-word;
      overscroll-behavior: contain;
    }
    .stats-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 12px;
    }
    .stat-card {
      padding: 18px;
      border-radius: var(--radius-md);
      border: 1px solid var(--border-soft);
      background: var(--surface-2);
      transition: border-color var(--ease), transform var(--ease), box-shadow var(--ease);
    }
    .stat-card strong {
      display: block;
      margin-bottom: 8px;
      font-size: 12px;
      font-weight: 600;
      letter-spacing: 0.04em;
      color: var(--text-muted);
    }
    .value {
      font-size: 24px;
      font-weight: 700;
      letter-spacing: -0.02em;
      line-height: 1.15;
      word-break: break-all;
    }
    .stat-note {
      margin: 8px 0 0;
      font-size: 14px;
      line-height: 1.6;
      color: var(--text-muted);
    }
    .stat-card[data-tone="live"] {
      border-color: rgba(37, 99, 235, 0.18);
    }
    .stat-card[data-tone="warning"] {
      border-color: rgba(217, 119, 6, 0.22);
    }
    .stat-card[data-tone="danger"] {
      border-color: rgba(220, 38, 38, 0.20);
    }
    .action-panel {
      display: grid;
      gap: 14px;
    }
    .action-toolbar {
      margin-bottom: 0;
    }
    .panel-status {
      margin: 0;
      padding: 15px 16px;
      border-radius: var(--radius-md);
      border: 1px solid var(--border-soft);
      background: var(--surface-2);
      color: var(--text-muted);
      line-height: 1.7;
      font-size: 14px;
    }
    .side-card.compact-card {
      padding: 20px;
    }
    .side-card.compact-card .section-head {
      margin-bottom: 16px;
    }
    .side-card.compact-card .section-sub {
      font-size: 14px;
      line-height: 1.65;
    }
    .log-card {
      padding: 20px;
      border-radius: var(--radius-md);
      border: 1px solid var(--border-soft);
      background: var(--surface-2);
      transition: border-color var(--ease), transform var(--ease);
    }
    .side-card.compact-card .log-card {
      padding: 16px;
    }
    .log-card h3 {
      margin: 0 0 8px;
      font-size: 18px;
      letter-spacing: -0.02em;
    }
    .log-card p {
      margin: 0 0 14px;
      color: var(--text-muted);
      line-height: 1.7;
      font-size: 14px;
    }
    .log-card .inline-status {
      margin-bottom: 12px;
    }
    .sr-only {
      position: absolute;
      width: 1px;
      height: 1px;
      padding: 0;
      margin: -1px;
      overflow: hidden;
      clip: rect(0, 0, 0, 0);
      white-space: nowrap;
      border: 0;
    }
    .result {
      margin-top: 16px;
      padding: 15px 16px;
      border-radius: var(--radius-md);
      border: 1px solid transparent;
      font-size: 14px;
      white-space: pre-wrap;
      word-break: break-word;
      background: rgba(37, 99, 235, 0.08);
      color: var(--accent-deep);
      transition: opacity var(--ease), transform var(--ease), border-color var(--ease), background-color var(--ease);
    }
    .result.success {
      background: rgba(37, 99, 235, 0.08);
      color: var(--accent-deep);
      border-color: rgba(37, 99, 235, 0.12);
    }
    .result.error {
      background: rgba(220, 38, 38, 0.08);
      color: #991b1b;
      border-color: rgba(220, 38, 38, 0.12);
    }
    .result.info {
      background: rgba(217, 119, 6, 0.08);
      color: #9a3412;
      border-color: rgba(217, 119, 6, 0.12);
    }
    .foot {
      margin-top: 20px;
      color: var(--text-muted);
      font-size: 13px;
      text-align: center;
      line-height: 1.7;
    }
    .modal {
      position: fixed;
      inset: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 20px;
      background: rgba(15, 23, 42, 0.36);
      opacity: 0;
      visibility: hidden;
      pointer-events: none;
      transition: opacity var(--ease), visibility var(--ease);
      z-index: 999;
    }
    .modal.open {
      opacity: 1;
      visibility: visible;
      pointer-events: auto;
    }
    @supports (backdrop-filter: blur(12px)) {
      .modal {
        backdrop-filter: blur(6px);
      }
    }
    .modal-panel {
      width: min(920px, 100%);
      height: min(620px, calc(100vh - 40px));
      display: grid;
      grid-template-rows: auto 1fr;
      background: rgba(255, 255, 255, 0.98);
      border: 1px solid var(--border-soft);
      border-radius: var(--radius-xl);
      box-shadow: var(--shadow-strong);
      overflow: hidden;
      opacity: 0;
      transform: translateY(10px) scale(0.985);
      transition: transform var(--ease), opacity var(--ease);
    }
    .modal.open .modal-panel {
      opacity: 1;
      transform: translateY(0) scale(1);
    }
    .modal-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 14px;
      padding: 18px 22px;
      border-bottom: 1px solid var(--border-soft);
      background: #fbfdff;
    }
    .modal-head h3 {
      margin: 0;
      font-size: 20px;
      letter-spacing: -0.02em;
    }
    .modal-actions {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
    }
    .modal-body {
      padding: 18px 22px 22px;
      overflow: hidden;
      background: var(--surface-2);
    }
    body.modal-open {
      overflow: hidden;
    }
    [data-scope-panel].is-busy {
      border-color: rgba(37, 99, 235, 0.18);
      box-shadow: 0 0 0 4px rgba(37, 99, 235, 0.06);
    }
    .flash {
      animation: panelPulse 420ms ease;
    }
    .reveal {
      opacity: 0;
      transform: translateY(10px);
      animation: riseIn 420ms cubic-bezier(.2,.8,.2,1) forwards;
    }
    .reveal[data-delay="1"] { animation-delay: 40ms; }
    .reveal[data-delay="2"] { animation-delay: 80ms; }
    .reveal[data-delay="3"] { animation-delay: 120ms; }
    .reveal[data-delay="4"] { animation-delay: 160ms; }
    @keyframes riseIn {
      to {
        opacity: 1;
        transform: translateY(0);
      }
    }
    @keyframes panelPulse {
      0% { box-shadow: 0 0 0 0 rgba(37, 99, 235, 0.00); }
      40% { box-shadow: 0 0 0 6px rgba(37, 99, 235, 0.08); }
      100% { box-shadow: 0 0 0 0 rgba(37, 99, 235, 0.00); }
    }
    @media (max-width: 1024px) {
      .layout {
        grid-template-columns: 1fr;
      }
      .sidebar {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }
      .sidebar > :last-child {
        grid-column: 1 / -1;
      }
    }
    @media (max-width: 1100px) {
      .workspace,
      .side-card {
        padding: 22px;
      }
      h2 {
        font-size: 30px;
      }
      textarea {
        min-height: clamp(360px, 46vh, 560px);
      }
    }
    @media (max-width: 768px) {
      .page-shell {
        width: min(100% - 20px, 1220px);
        margin: 20px auto 28px;
      }
      .workspace,
      .side-card {
        padding: 18px;
      }
      .stats-grid,
      .sidebar {
        grid-template-columns: 1fr;
      }
      .section-head {
        align-items: flex-start;
      }
      .section-copy.section-meta {
        flex-basis: 100%;
      }
      .toolbar-group,
      .toolbar-group.primary-group {
        flex: 1 1 100%;
        justify-content: stretch;
      }
      .toolbar-group button,
      .modal-actions button {
        flex: 1 1 0;
      }
      .modal-head {
        position: sticky;
        top: 0;
        z-index: 1;
      }
      .modal-actions {
        width: 100%;
      }
    }
    @media (max-width: 560px) {
      h2 {
        font-size: 28px;
      }
      .editor-topbar,
      .modal-head,
      .modal-body {
        padding-left: 16px;
        padding-right: 16px;
      }
      .modal-panel {
        height: min(640px, calc(100vh - 24px));
      }
      .value {
        font-size: 21px;
      }
      textarea {
        min-height: 320px;
        padding: 16px;
      }
    }
    @media (prefers-reduced-motion: reduce) {
      *,
      *::before,
      *::after {
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
        transition-duration: 0.01ms !important;
        scroll-behavior: auto !important;
      }
    }
  </style>
</head>
<body>
  <div class="page-shell">
    <main class="layout">
      <section class="workspace card reveal" data-delay="2" data-scope-panel="config">
        <div class="section-head">
          <div class="section-copy">
            <p class="section-kicker">配置工作区</p>
            <h2>配置编辑器</h2>
            <p class="section-sub">面向稳定维护的配置工作区。建议先校验，再决定是只保存还是保存后立刻重启服务。</p>
          </div>
          <div class="section-copy section-meta">
            <p class="section-kicker">配置来源</p>
            <p class="section-sub" style="margin-top:0;"><code>/usr/local/frpc/frpc.toml</code></p>
          </div>
        </div>

        <div class="toolbar">
          <div class="toolbar-group">
            <button id="refreshConfigBtn" data-busy-scope="config" data-loading-text="正在刷新...">刷新配置</button>
            <button id="verifyConfigBtn" data-busy-scope="config" data-loading-text="正在校验...">校验配置</button>
          </div>
          <div class="toolbar-group primary-group">
            <button id="saveConfigBtn" class="warn" data-busy-scope="config" data-loading-text="正在保存...">保存配置</button>
            <button id="saveRestartBtn" class="primary" data-busy-scope="config" data-loading-text="正在保存并重启...">保存并重启</button>
          </div>
        </div>

        <div class="section-note">
          <label class="field-label" for="configBox">frpc.toml</label>
          <p id="configStatus" class="inline-status">等待读取配置。</p>
        </div>

        <div id="editorShell" class="editor-shell" data-state="saved">
          <div class="editor-topbar">
            <span id="dirtyBadge" class="state-pill">已保存</span>
            <p id="configMeta" class="inline-status">最近一次成功保存后会在这里显示时间。</p>
          </div>
          <textarea id="configBox" spellcheck="false" aria-describedby="configMeta configStatus"></textarea>
        </div>

        <div id="resultBox" class="result info" role="status" aria-live="polite" aria-atomic="true">等待操作。</div>
      </section>

      <aside class="sidebar">
        <section class="side-card card reveal" data-delay="2" data-scope-panel="service">
          <div class="section-head">
            <div class="section-copy">
              <p class="section-kicker">运行概览</p>
              <h2>服务概览</h2>
              <p class="section-sub">这里聚合当前运行态、版本与配置更新时间，适合在执行服务操作前快速确认。</p>
            </div>
          </div>
          <div class="stats-grid">
            <article id="activeCard" class="stat-card" data-tone="live">
              <strong>运行状态</strong>
              <div id="active" class="value">-</div>
              <p id="activeNote" class="stat-note">等待查询当前服务状态。</p>
            </article>
            <article id="enabledCard" class="stat-card">
              <strong>开机自启</strong>
              <div id="enabled" class="value">-</div>
              <p id="enabledNote" class="stat-note">等待查询是否随系统启动。</p>
            </article>
            <article id="versionCard" class="stat-card">
              <strong>frpc 版本</strong>
              <div id="version" class="value">-</div>
              <p id="versionNote" class="stat-note">等待读取当前二进制版本。</p>
            </article>
            <article id="mtimeCard" class="stat-card">
              <strong>配置文件时间</strong>
              <div id="mtime" class="value">-</div>
              <p id="mtimeNote" class="stat-note">等待读取配置文件修改时间。</p>
            </article>
          </div>
        </section>

        <section class="side-card card reveal" data-delay="3" data-scope-panel="service">
          <div class="section-head">
            <div class="section-copy">
              <p class="section-kicker">服务操作</p>
              <h2>服务操作</h2>
              <p class="section-sub">适合在确认运行态后执行启动、重启或停止操作。</p>
            </div>
          </div>
          <div class="action-panel">
            <p id="serviceStatus" class="sr-only" aria-live="polite">等待查询服务状态。</p>
            <div class="toolbar action-toolbar">
              <div class="toolbar-group">
                <button id="startServiceBtn" class="primary" data-busy-scope="service" data-loading-text="正在启动...">启动</button>
                <button id="restartServiceBtn" class="warn" data-busy-scope="service" data-loading-text="正在重启...">重启</button>
                <button id="stopServiceBtn" class="danger" data-busy-scope="service" data-loading-text="正在停止...">停止</button>
              </div>
            </div>
          </div>
        </section>

        <section class="side-card card compact-card reveal" data-delay="4" data-scope-panel="logs">
          <div class="section-head">
            <div class="section-copy">
              <p class="section-kicker">日志</p>
              <h2>日志入口</h2>
              <p class="section-sub">日志只在你打开弹窗时读取，避免主界面被大量输出拖慢。</p>
            </div>
          </div>
          <div class="log-card">
            <h3>最近 120 行服务日志</h3>
            <p id="logsStatus" class="inline-status" aria-live="polite">日志按需加载，打开弹窗后可滚动查看。</p>
            <button id="openLogsBtn" class="warn" data-busy-scope="logs" data-loading-text="正在读取日志..." aria-haspopup="dialog" aria-controls="logsModal" aria-expanded="false">查看日志</button>
          </div>
        </section>
      </aside>
    </main>

    <div class="foot">建议把 Web 控制台限制在防火墙、跳板机或受限内网范围内使用，以避免把 <code>frpc</code> 管理能力直接暴露出去。</div>
  </div>

  <div id="logsModal" class="modal" aria-hidden="true">
    <div id="logsDialog" class="modal-panel" role="dialog" aria-modal="true" aria-labelledby="logsTitle" tabindex="-1">
      <div class="modal-head">
        <h3 id="logsTitle">frpc 最近日志</h3>
        <div class="modal-actions">
          <button id="refreshLogsBtn" data-busy-scope="logs" data-loading-text="正在刷新日志...">刷新日志</button>
          <button id="closeLogsBtn" class="close-btn">关闭</button>
        </div>
      </div>
      <div class="modal-body">
        <pre id="logsBox" tabindex="0" aria-label="frpc 最近日志内容">正在读取日志...</pre>
      </div>
    </div>
  </div>

  <script>
    const els = {
      configBox: document.getElementById('configBox'),
      resultBox: document.getElementById('resultBox'),
      configStatus: document.getElementById('configStatus'),
      configMeta: document.getElementById('configMeta'),
      dirtyBadge: document.getElementById('dirtyBadge'),
      editorShell: document.getElementById('editorShell'),
      serviceStatus: document.getElementById('serviceStatus'),
      logsStatus: document.getElementById('logsStatus'),
      active: document.getElementById('active'),
      enabled: document.getElementById('enabled'),
      version: document.getElementById('version'),
      mtime: document.getElementById('mtime'),
      activeCard: document.getElementById('activeCard'),
      enabledCard: document.getElementById('enabledCard'),
      versionCard: document.getElementById('versionCard'),
      mtimeCard: document.getElementById('mtimeCard'),
      activeNote: document.getElementById('activeNote'),
      enabledNote: document.getElementById('enabledNote'),
      versionNote: document.getElementById('versionNote'),
      mtimeNote: document.getElementById('mtimeNote'),
      logsModal: document.getElementById('logsModal'),
      logsDialog: document.getElementById('logsDialog'),
      logsBox: document.getElementById('logsBox'),
      openLogsBtn: document.getElementById('openLogsBtn'),
      closeLogsBtn: document.getElementById('closeLogsBtn'),
      refreshConfigBtn: document.getElementById('refreshConfigBtn'),
      verifyConfigBtn: document.getElementById('verifyConfigBtn'),
      saveConfigBtn: document.getElementById('saveConfigBtn'),
      saveRestartBtn: document.getElementById('saveRestartBtn'),
      startServiceBtn: document.getElementById('startServiceBtn'),
      restartServiceBtn: document.getElementById('restartServiceBtn'),
      stopServiceBtn: document.getElementById('stopServiceBtn'),
      refreshLogsBtn: document.getElementById('refreshLogsBtn')
    };

    const state = {
      busy: { config: false, service: false, logs: false },
      config: { loaded: '', saved: '', dirty: false, lastSavedAt: null },
      modal: { logsOpen: false, lastActive: null },
      requestSeq: { status: 0, config: 0, logs: 0 }
    };

    function setResult(message, type = 'info') {
      els.resultBox.textContent = message;
      els.resultBox.className = `result ${type}`;
      pulseCard(els.resultBox);
    }

    function setText(node, text) {
      if (!node) return;
      node.textContent = text;
    }

    function formatTime(ts) {
      if (!ts) return '-';
      return new Date(ts * 1000).toLocaleString('zh-CN', { hour12: false });
    }

    function formatNow() {
      return new Date().toLocaleString('zh-CN', { hour12: false });
    }

    function setTone(element, tone) {
      if (!element) return;
      if (tone) {
        element.dataset.tone = tone;
      } else {
        delete element.dataset.tone;
      }
    }

    function pulseCard(element) {
      if (!element) return;
      element.classList.remove('flash');
      void element.offsetWidth;
      element.classList.add('flash');
      window.setTimeout(() => element.classList.remove('flash'), 450);
    }

    async function request(url, options = {}) {
      const controller = new AbortController();
      const timeoutId = window.setTimeout(() => controller.abort(), 12000);

      try {
        const response = await fetch(url, {
          headers: { 'Content-Type': 'application/json' },
          ...options,
          signal: controller.signal
        });
        const data = await response.json().catch(() => ({ ok: false, message: '接口返回异常' }));
        if (!response.ok || data.ok === false) {
          throw new Error(data.message || '请求失败');
        }
        return data;
      } catch (error) {
        if (error.name === 'AbortError') {
          throw new Error('请求超时，请稍后重试。');
        }
        throw error;
      } finally {
        window.clearTimeout(timeoutId);
      }
    }

    function updateSaveButtons() {
      const disabled = state.busy.config || !state.config.dirty;
      els.saveConfigBtn.disabled = disabled;
      els.saveRestartBtn.disabled = disabled;
    }

    function setBusy(scope, on, text = '') {
      state.busy[scope] = on;

      document.querySelectorAll(`[data-busy-scope="${scope}"]`).forEach((button) => {
        if (on) {
          button.dataset.originalText = button.dataset.originalText || button.textContent;
          button.disabled = true;
          if (button.dataset.loadingText) {
            button.textContent = button.dataset.loadingText;
          }
        } else {
          button.disabled = false;
          if (button.dataset.originalText) {
            button.textContent = button.dataset.originalText;
          }
        }
      });

      if (text) {
        if (scope === 'config') setText(els.configStatus, text);
        if (scope === 'service') setText(els.serviceStatus, text);
        if (scope === 'logs') setText(els.logsStatus, text);
      }

      document.querySelectorAll(`[data-scope-panel="${scope}"]`).forEach((panel) => {
        panel.classList.toggle('is-busy', on);
      });

      if (scope === 'config') {
        els.editorShell.classList.toggle('is-busy', on);
      }

      updateSaveButtons();
    }

    async function withBusy(scope, text, fn) {
      if (state.busy[scope]) return;
      setBusy(scope, true, text);
      try {
        return await fn();
      } finally {
        setBusy(scope, false);
      }
    }

    function updateDirtyState() {
      state.config.dirty = els.configBox.value !== state.config.saved;
      els.editorShell.dataset.state = state.config.dirty ? 'dirty' : 'saved';

      if (state.config.dirty) {
        els.dirtyBadge.className = 'state-pill dirty';
        setText(els.dirtyBadge, '有未保存修改');
        setText(els.configMeta, '当前编辑内容尚未保存，刷新配置前会提示确认。');
      } else {
        els.dirtyBadge.className = 'state-pill';
        setText(els.dirtyBadge, '已保存');
        setText(els.configMeta, state.config.lastSavedAt ? `最近一次保存时间：${state.config.lastSavedAt}` : '最近一次成功保存后会在这里显示时间。');
      }

      updateSaveButtons();
    }

    function rememberLoadedConfig(content) {
      state.config.loaded = content;
      state.config.saved = content;
      els.configBox.value = content;
      updateDirtyState();
    }

    function confirmDiscardChanges() {
      if (!state.config.dirty) return true;
      return window.confirm('当前有未保存修改，确认覆盖吗？');
    }

    async function refreshStatus(options = {}) {
      const requestId = ++state.requestSeq.status;

      const load = async () => {
        const data = await request('/api/status');
        if (requestId !== state.requestSeq.status) return;

        const service = data.data;
        setText(els.active, service.active);
        setText(els.enabled, service.enabled);
        setText(els.version, service.version);
        setText(els.mtime, formatTime(service.config_mtime));

        setText(els.activeNote, service.active === 'active' ? '服务当前可用，适合继续执行配置或日志操作。' : '服务当前不在 active 状态，请优先检查日志。');
        setText(els.enabledNote, service.enabled === 'enabled' ? '系统启动后会自动尝试拉起。' : '当前未设置为随系统启动。');
        setText(els.versionNote, '当前已安装并可执行的 frpc 版本。');
        setText(els.mtimeNote, service.config_mtime ? '最近一次配置文件落盘时间。' : '尚未检测到配置文件时间。');

        setTone(els.activeCard, service.active === 'active' ? 'live' : 'danger');
        setTone(els.enabledCard, service.enabled === 'enabled' ? 'live' : 'warning');
        setTone(els.versionCard, 'live');
        setTone(els.mtimeCard, service.config_mtime ? 'live' : 'warning');

        pulseCard(els.activeCard);
        pulseCard(els.enabledCard);
        pulseCard(els.versionCard);
        pulseCard(els.mtimeCard);

        setText(els.serviceStatus, '服务状态已刷新。');
      };

      if (options.silent) {
        return load();
      }

      return withBusy('service', '正在刷新服务状态...', load).catch((error) => {
        setText(els.serviceStatus, '刷新服务状态失败。');
        setResult(error.message, 'error');
      });
    }

    async function refreshConfig(options = {}) {
      const requestId = ++state.requestSeq.config;

      const load = async () => {
        const data = await request('/api/config');
        if (requestId !== state.requestSeq.config) return;

        const content = data.data.content || '';
        rememberLoadedConfig(content);
        setText(els.configStatus, '配置已刷新。');
        setResult('配置已刷新。', 'success');
      };

      if (!options.force && !confirmDiscardChanges()) {
        setText(els.configStatus, '已取消刷新，保留当前未保存修改。');
        return;
      }

      return withBusy('config', '正在读取配置...', load).catch((error) => {
        setText(els.configStatus, '读取配置失败。');
        setResult(error.message, 'error');
      });
    }

    async function verifyConfig() {
      return withBusy('config', '正在校验配置...', async () => {
        const content = els.configBox.value;
        const data = await request('/api/verify', {
          method: 'POST',
          body: JSON.stringify({ content })
        });
        setText(els.configStatus, '配置校验通过。');
        setResult(data.message || '配置校验通过。', 'success');
      }).catch((error) => {
        setText(els.configStatus, '配置校验失败。');
        setResult(error.message, 'error');
      });
    }

    async function saveConfig(restart) {
      return withBusy('config', restart ? '正在保存配置并重启...' : '正在保存配置...', async () => {
        const content = els.configBox.value;
        const data = await request('/api/config', {
          method: 'POST',
          body: JSON.stringify({ content, restart })
        });

        state.config.saved = content;
        state.config.loaded = content;
        state.config.lastSavedAt = formatNow();
        updateDirtyState();

        setText(els.configStatus, restart ? '配置已保存，frpc 已重启。' : '配置已保存。');
        setResult(data.message || (restart ? '配置已保存，frpc 已重启。' : '配置已保存。'), 'success');

        const followUps = [refreshStatus({ silent: true })];
        if (state.modal.logsOpen) {
          followUps.push(refreshLogs({ silent: true }));
        }
        await Promise.allSettled(followUps);
      }).catch((error) => {
        setText(els.configStatus, '配置保存失败。');
        setResult(error.message, 'error');
      });
    }

    async function serviceAction(action) {
      const actionMap = {
        start: '正在启动 frpc...',
        stop: '正在停止 frpc...',
        restart: '正在重启 frpc...'
      };

      return withBusy('service', actionMap[action] || '正在执行服务操作...', async () => {
        const data = await request('/api/service', {
          method: 'POST',
          body: JSON.stringify({ action })
        });
        setText(els.serviceStatus, `frpc 已执行 ${action}。`);
        setResult(data.message || (`已执行 ${action}`), 'success');

        const followUps = [refreshStatus({ silent: true })];
        if (state.modal.logsOpen) {
          followUps.push(refreshLogs({ silent: true }));
        }
        await Promise.allSettled(followUps);
      }).catch((error) => {
        setText(els.serviceStatus, '服务操作失败。');
        setResult(error.message, 'error');
      });
    }

    async function refreshLogs(options = {}) {
      const requestId = ++state.requestSeq.logs;

      const load = async () => {
        const data = await request('/api/logs');
        if (requestId !== state.requestSeq.logs) return;

        setText(els.logsBox, data.data.logs || '暂无日志。');
        setText(els.logsStatus, `日志已刷新：${formatNow()}`);
      };

      if (options.silent) {
        return load();
      }

      return withBusy('logs', '正在读取日志...', load).catch((error) => {
        setText(els.logsStatus, `日志读取失败：${error.message}`);
      });
    }

    function getFocusableElements(container) {
      return Array.from(container.querySelectorAll('button, [href], textarea, input, select, [tabindex]:not([tabindex="-1"])'))
        .filter((element) => !element.disabled && element.offsetParent !== null);
    }

    function handleModalKeydown(event) {
      if (!state.modal.logsOpen) return;

      if (event.key === 'Escape') {
        event.preventDefault();
        closeLogsModal();
        return;
      }

      if (event.key !== 'Tab') return;

      const focusables = getFocusableElements(els.logsDialog);
      if (focusables.length === 0) return;

      const first = focusables[0];
      const last = focusables[focusables.length - 1];

      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }

    async function openLogsModal() {
      if (state.modal.logsOpen) return;
      state.modal.logsOpen = true;
      state.modal.lastActive = document.activeElement;
      els.logsModal.classList.add('open');
      els.logsModal.setAttribute('aria-hidden', 'false');
      els.openLogsBtn.setAttribute('aria-expanded', 'true');
      document.body.classList.add('modal-open');
      els.closeLogsBtn.focus();
      await refreshLogs();
    }

    function closeLogsModal() {
      if (!state.modal.logsOpen) return;
      state.modal.logsOpen = false;
      els.logsModal.classList.remove('open');
      els.logsModal.setAttribute('aria-hidden', 'true');
      els.openLogsBtn.setAttribute('aria-expanded', 'false');
      document.body.classList.remove('modal-open');
      if (state.modal.lastActive instanceof HTMLElement) {
        state.modal.lastActive.focus();
      } else {
        els.openLogsBtn.focus();
      }
    }

    async function boot() {
      updateSaveButtons();
      try {
        await Promise.all([refreshStatus({ silent: true }), refreshConfig({ force: true })]);
        setText(els.serviceStatus, '服务状态已加载。');
        setText(els.configStatus, '配置已加载。');
        setResult('面板已准备就绪。', 'success');
      } catch (error) {
        setResult(error.message, 'error');
      }
    }

    els.configBox.addEventListener('input', updateDirtyState);
    els.refreshConfigBtn.addEventListener('click', () => refreshConfig());
    els.verifyConfigBtn.addEventListener('click', () => verifyConfig());
    els.saveConfigBtn.addEventListener('click', () => saveConfig(false));
    els.saveRestartBtn.addEventListener('click', () => saveConfig(true));
    els.startServiceBtn.addEventListener('click', () => serviceAction('start'));
    els.restartServiceBtn.addEventListener('click', () => serviceAction('restart'));
    els.stopServiceBtn.addEventListener('click', () => serviceAction('stop'));
    els.openLogsBtn.addEventListener('click', () => openLogsModal());
    els.closeLogsBtn.addEventListener('click', closeLogsModal);
    els.refreshLogsBtn.addEventListener('click', () => refreshLogs());
    els.logsModal.addEventListener('click', (event) => {
      if (event.target === els.logsModal) {
        closeLogsModal();
      }
    });

    window.addEventListener('beforeunload', (event) => {
      if (!state.config.dirty) return;
      event.preventDefault();
      event.returnValue = '';
    });

    document.addEventListener('keydown', (event) => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 's') {
        event.preventDefault();
        if (state.config.dirty && !state.busy.config) {
          saveConfig(false);
        }
        return;
      }

      handleModalKeydown(event);
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
  local active_state enabled_state

  systemctl daemon-reload
  systemctl enable "${service_name}" >/dev/null

  if ! systemctl restart "${service_name}"; then
    systemctl --no-pager --full status "${service_name}" || true
    echo "错误: ${service_name} 启动失败，请检查配置或网络连通性。"
    return 1
  fi

  active_state="$(systemctl is-active "${service_name}" 2>/dev/null || true)"
  enabled_state="$(systemctl is-enabled "${service_name}" 2>/dev/null || true)"
  systemctl --no-pager --full status "${service_name}" || true

  if [[ "${active_state}" != "active" ]]; then
    echo "错误: ${service_name} 当前状态为 ${active_state:-unknown}，未成功进入 active。"
    return 1
  fi

  echo "${service_name} 已启动，当前状态: ${active_state}，开机自启: ${enabled_state:-unknown}"
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

  mkdir -p "${FRPS_DIR}"
  backup_file "${FRPS_SERVICE}"

  download_release_bundle "frps" "${arch}"
  install_release_binary "frps" "${FRPS_DIR}"
  write_frps_config
  verify_config_with_binary "${FRPS_DIR}/frps" "${FRPS_DIR}/frps.toml" "frps"
  write_frps_service

  if is_service_registered "frps.service"; then
    systemctl stop frps.service || true
  fi

  enable_service "frps.service"

  echo
  echo "frps 安装完成。"
  echo "配置文件: ${FRPS_DIR}/frps.toml"
  echo "服务管理: systemctl status|restart|stop frps"
}

install_frpc() {
  local arch
  arch="$(detect_arch)"

  mkdir -p "${FRPC_DIR}"
  backup_file "${FRPC_SERVICE}"
  backup_file "${FRPC_WEB_SERVICE}"

  download_release_bundle "frpc" "${arch}"
  install_release_binary "frpc" "${FRPC_DIR}"
  write_frpc_config
  verify_config_with_binary "${FRPC_DIR}/frpc" "${FRPC_DIR}/frpc.toml" "frpc"
  write_frpc_service

  if is_service_registered "frpc.service"; then
    systemctl stop frpc.service || true
  fi
  if is_service_registered "frpc-web.service"; then
    systemctl stop frpc-web.service || true
  fi

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
  local arch backup_dir
  arch="$(detect_arch)"

  if [[ ! -x "${FRPS_DIR}/frps" ]]; then
    echo "未检测到已安装的 frps: ${FRPS_DIR}/frps"
    echo "请先执行安装。"
    exit 1
  fi

  download_release_bundle "frps" "${arch}"
  verify_config_with_binary "${RELEASE_EXTRACT_DIR}/frps" "${FRPS_DIR}/frps.toml" "frps"
  backup_dir="$(create_runtime_backup "${FRPS_DIR}" "frps")"

  if is_service_registered "frps.service"; then
    systemctl stop frps.service || true
  fi

  if ! install_release_binary "frps" "${FRPS_DIR}"; then
    echo "安装新版本 frps 失败，正在恢复上一版本..."
    restore_runtime_backup "${backup_dir}" "${FRPS_DIR}" "frps"
    return 1
  fi

  if [[ ! -f "${FRPS_SERVICE}" ]]; then
    echo "未检测到 frps.service，正在重新生成服务文件。"
    write_frps_service
  fi

  if ! enable_service "frps.service"; then
    echo "frps 新版本启动失败，正在回滚上一版本..."
    restore_runtime_backup "${backup_dir}" "${FRPS_DIR}" "frps"
    if ! enable_service "frps.service"; then
      echo "回滚后 frps 仍未能启动，请手动检查 ${FRPS_DIR} 与 ${FRPS_SERVICE}。"
      return 1
    fi
    echo "已回滚到上一版本 frps。"
    return 1
  fi

  echo
  echo "frps 更新完成。"
  echo "配置文件保持不变: ${FRPS_DIR}/frps.toml"
  echo "服务管理: systemctl status|restart|stop frps"
}

update_frpc() {
  local arch backup_dir refresh_web_panel="n"
  arch="$(detect_arch)"

  if [[ ! -x "${FRPC_DIR}/frpc" ]]; then
    echo "未检测到已安装的 frpc: ${FRPC_DIR}/frpc"
    echo "请先执行安装。"
    exit 1
  fi

  if [[ -f "${FRPC_WEB_CONFIG}" || -f "${FRPC_WEB_SERVICE}" ]]; then
    refresh_web_panel="y"
  fi

  download_release_bundle "frpc" "${arch}"
  verify_config_with_binary "${RELEASE_EXTRACT_DIR}/frpc" "${FRPC_DIR}/frpc.toml" "frpc"
  backup_dir="$(create_runtime_backup "${FRPC_DIR}" "frpc")"

  if is_service_registered "frpc.service"; then
    systemctl stop frpc.service || true
  fi
  if is_service_registered "frpc-web.service"; then
    systemctl stop frpc-web.service || true
  fi

  if ! install_release_binary "frpc" "${FRPC_DIR}"; then
    echo "安装新版本 frpc 失败，正在恢复上一版本..."
    restore_runtime_backup "${backup_dir}" "${FRPC_DIR}" "frpc"
    return 1
  fi

  if [[ ! -f "${FRPC_SERVICE}" ]]; then
    echo "未检测到 frpc.service，正在重新生成服务文件。"
    write_frpc_service
  fi

  if ! enable_service "frpc.service"; then
    echo "frpc 新版本启动失败，正在回滚上一版本..."
    restore_runtime_backup "${backup_dir}" "${FRPC_DIR}" "frpc"
    if ! enable_service "frpc.service"; then
      echo "回滚后 frpc 仍未能启动，请手动检查 ${FRPC_DIR} 与 ${FRPC_SERVICE}。"
      return 1
    fi
    echo "已回滚到上一版本 frpc。"
    return 1
  fi

  if [[ "${refresh_web_panel}" == "y" ]]; then
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
