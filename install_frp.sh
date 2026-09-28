#!/usr/bin/env bash

set -euo pipefail

readonly FRP_REPO_API="https://api.github.com/repos/fatedier/frp/releases/latest"
readonly FRPC_WEB_REPO_API="https://api.github.com/repos/mfblog/frp-webs/releases/latest"
readonly GITHUB_ACCEL_PREFIX="${FRP_GITHUB_ACCEL_PREFIX:-}"
readonly FRPS_DIR="/usr/local/frps"
readonly FRPC_DIR="/usr/local/frpc"
readonly FRPC_WEB_DIR="/usr/local/frpc/web"
readonly FRPC_WEB_BINARY="/usr/local/frpc/web/frpc-web"
readonly FRPC_WEB_LEGACY_ENV="/etc/frpc-web.env"
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
  local packages=(curl jq tar)
  local missing=()

  for pkg in "${packages[@]}"; do
    if ! command -v "${pkg}" >/dev/null 2>&1; then
      missing+=("${pkg}")
    fi
  done

  if ! command -v sha256sum >/dev/null 2>&1; then
    missing+=(coreutils)
  fi

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
  if [[ ! "${GITHUB_ACCEL_PREFIX}" =~ ^https:// ]]; then
    echo "FRP_GITHUB_ACCEL_PREFIX 必须使用 HTTPS。" >&2
    return 1
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

  mkdir -p "${install_dir}" || return $?
  install -m 755 "${RELEASE_EXTRACT_DIR}/${app_name}" "${install_dir}/${app_name}" || return $?

  if [[ -f "${RELEASE_EXTRACT_DIR}/LICENSE" ]]; then
    install -m 644 "${RELEASE_EXTRACT_DIR}/LICENSE" "${install_dir}/LICENSE" || return $?
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

download_frpc_web_binary() {
  local arch="${1}"
  local release_json tag_name asset_name checksum_name download_url checksum_url
  local web_release_dir expected_checksum actual_checksum

  echo "正在获取 frpc Web 控制台最新版本信息..."
  release_json="$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$(build_accel_url "${FRPC_WEB_REPO_API}")")"
  tag_name="$(jq -r '.tag_name' <<<"${release_json}")"

  if [[ -z "${tag_name}" || "${tag_name}" == "null" ]]; then
    echo "获取 frpc Web 控制台版本失败。"
    return 1
  fi

  asset_name="frpc-web-linux-${arch}"
  checksum_name="SHA256SUMS"
  download_url="$(jq -r --arg name "${asset_name}" '.assets[] | select(.name == $name) | .browser_download_url' <<<"${release_json}")"
  checksum_url="$(jq -r --arg name "${checksum_name}" '.assets[] | select(.name == $name) | .browser_download_url' <<<"${release_json}")"

  if [[ -z "${download_url}" || "${download_url}" == "null" ]]; then
    echo "Release 中未找到当前架构的控制台二进制: ${asset_name}"
    return 1
  fi
  if [[ -z "${checksum_url}" || "${checksum_url}" == "null" ]]; then
    echo "Release 中未找到 ${checksum_name}，拒绝安装未经校验的控制台二进制。"
    return 1
  fi

  if [[ -z "${TEMP_DIR}" ]]; then
    TEMP_DIR="$(mktemp -d)"
  fi
  web_release_dir="${TEMP_DIR}/frpc-web-${tag_name}"
  mkdir -p "${web_release_dir}"

  echo "正在下载 ${asset_name} ..."
  curl -fL "$(build_accel_url "${download_url}")" -o "${web_release_dir}/${asset_name}"
  curl -fsSL "$(build_accel_url "${checksum_url}")" -o "${web_release_dir}/${checksum_name}"

  expected_checksum="$(awk -v name="${asset_name}" '$2 == name || $2 == "*" name {print $1; exit}' "${web_release_dir}/${checksum_name}")"
  actual_checksum="$(sha256sum "${web_release_dir}/${asset_name}" | awk '{print $1}')"
  if [[ -z "${expected_checksum}" || "${actual_checksum}" != "${expected_checksum}" ]]; then
    echo "frpc Web 控制台二进制 SHA-256 校验失败。"
    return 1
  fi

  mkdir -p "${FRPC_WEB_DIR}"
  backup_file "${FRPC_WEB_BINARY}"
  install -m 755 "${web_release_dir}/${asset_name}" "${FRPC_WEB_BINARY}"
  echo "已安装 frpc Web 控制台 ${tag_name} 到 ${FRPC_WEB_BINARY}"
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
ExecStart=${FRPC_WEB_BINARY} --listen 0.0.0.0:7410 --frpc-bin ${FRPC_DIR}/frpc --frpc-config ${FRPC_DIR}/frpc.toml --frpc-service frpc.service
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
}

setup_frpc_web_panel() {
  local arch
  arch="$(detect_arch)"

  download_frpc_web_binary "${arch}"
  backup_file "${FRPC_WEB_SERVICE}"
  write_frpc_web_service
  enable_service "frpc-web.service"
  rm -f "${FRPC_WEB_LEGACY_ENV}"

  echo "frpc Web 控制台已部署。"
  echo "监听地址: 0.0.0.0:7410"
  echo "访问地址: http://<服务器IP>:7410"
  echo "服务管理: systemctl status|restart|stop frpc-web"
  echo "提示: 控制台无登录认证，仅限可信内网访问，并请用防火墙限制来源；不要直接暴露到公网。"
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
  systemctl list-unit-files | grep "^${service_name}[[:space:]]" >/dev/null
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

restore_service_state() {
  local service_name="${1}"
  local active_state="${2}"
  local enabled_state="${3}"
  local failed="n"

  systemctl daemon-reload
  if [[ "${enabled_state}" == "enabled" ]]; then
    systemctl enable "${service_name}" >/dev/null 2>&1 || failed="y"
  else
    systemctl disable "${service_name}" >/dev/null 2>&1 || failed="y"
  fi

  if [[ "${active_state}" == "active" ]]; then
    systemctl restart "${service_name}" || failed="y"
  else
    systemctl stop "${service_name}" >/dev/null 2>&1 || failed="y"
  fi

  [[ "${failed}" == "n" ]]
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
  local arch config_ready="n"
  arch="$(detect_arch)"

  mkdir -p "${FRPC_DIR}"
  backup_file "${FRPC_SERVICE}"
  backup_file "${FRPC_WEB_SERVICE}"

  download_release_bundle "frpc" "${arch}"
  install_release_binary "frpc" "${FRPC_DIR}"
  write_frpc_service

  if [[ -f "${FRPC_DIR}/frpc.toml" ]]; then
    echo "检测到已有 frpc 配置，正在校验..."
    if verify_config_with_binary "${FRPC_DIR}/frpc" "${FRPC_DIR}/frpc.toml" "frpc"; then
      config_ready="y"
    else
      echo "现有配置校验失败，已保留原文件，请稍后在 Web 控制台中修复。"
    fi
  else
    echo "尚未创建 frpc 配置，将在 Web 控制台中完成首次配置。"
  fi

  setup_frpc_web_panel

  if is_service_registered "frpc.service"; then
    systemctl stop frpc.service || true
  fi

  systemctl daemon-reload

  if [[ "${config_ready}" != "y" ]]; then
    systemctl disable frpc.service >/dev/null 2>&1 || true
  fi

  if [[ "${config_ready}" == "y" ]] && ! enable_service "frpc.service"; then
    echo "frpc 启动失败，但 Web 控制台已可用。请通过网页检查配置和日志后重试。"
    return 1
  fi

  echo
  echo "frpc 安装完成。"
  if [[ "${config_ready}" == "y" ]]; then
    echo "已加载现有配置: ${FRPC_DIR}/frpc.toml"
  else
    echo "请打开上方 Web 控制台，填写并校验完整的 frpc.toml。"
    echo "首次点击“保存并启动”后，frpc 将设置为开机自启并启动。"
  fi
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
  local arch backup_dir config_ready="n" was_active="inactive" was_enabled="disabled"
  arch="$(detect_arch)"

  if [[ ! -x "${FRPC_DIR}/frpc" ]]; then
    echo "未检测到已安装的 frpc: ${FRPC_DIR}/frpc"
    echo "请先执行安装。"
    exit 1
  fi

  download_release_bundle "frpc" "${arch}"
  if [[ -f "${FRPC_DIR}/frpc.toml" ]]; then
    verify_config_with_binary "${RELEASE_EXTRACT_DIR}/frpc" "${FRPC_DIR}/frpc.toml" "frpc"
    config_ready="y"
  else
    echo "当前尚未创建 frpc 配置，本次仅更新二进制和 Web 控制台。"
  fi
  backup_dir="$(create_runtime_backup "${FRPC_DIR}" "frpc")"

  if is_service_registered "frpc.service"; then
    was_active="$(systemctl is-active frpc.service 2>/dev/null || true)"
    was_enabled="$(systemctl is-enabled frpc.service 2>/dev/null || true)"
    systemctl stop frpc.service || true
  fi

  if ! install_release_binary "frpc" "${FRPC_DIR}"; then
    echo "安装新版本 frpc 失败，正在恢复上一版本..."
    restore_runtime_backup "${backup_dir}" "${FRPC_DIR}" "frpc"
    if ! restore_service_state "frpc.service" "${was_active}" "${was_enabled}"; then
      echo "恢复 frpc 原服务状态失败，请手动检查。"
    fi
    return 1
  fi

  if [[ ! -f "${FRPC_SERVICE}" ]]; then
    echo "未检测到 frpc.service，正在重新生成服务文件。"
    write_frpc_service
  fi

  if [[ "${config_ready}" == "y" ]]; then
    if ! enable_service "frpc.service"; then
      echo "frpc 新版本启动失败，正在回滚上一版本..."
      restore_runtime_backup "${backup_dir}" "${FRPC_DIR}" "frpc"
      if ! restore_service_state "frpc.service" "${was_active}" "${was_enabled}"; then
        echo "回滚后 frpc 原服务状态恢复失败，请手动检查 ${FRPC_DIR} 与 ${FRPC_SERVICE}。"
        return 1
      fi
      echo "已回滚到上一版本 frpc。"
      return 1
    fi
  else
    systemctl daemon-reload
    systemctl disable frpc.service >/dev/null 2>&1 || true
  fi

  echo "正在刷新 frpc Web 控制台..."
  setup_frpc_web_panel

  echo
  echo "frpc 更新完成。"
  if [[ "${config_ready}" == "y" ]]; then
    echo "配置文件保持不变: ${FRPC_DIR}/frpc.toml"
  else
    echo "请在 Web 控制台中完成首次 frpc 配置。"
  fi
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
  rm -f "${FRPC_WEB_LEGACY_ENV}"
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
  echo "二进制: $([[ -x "${FRPC_WEB_BINARY}" ]] && echo 已安装 || echo 未安装)"
  echo "systemd 服务: $(service_state "frpc-web.service")"
  echo "开机自启: $(service_enabled_state "frpc-web.service")"
  echo "监听地址: 0.0.0.0:7410"
  echo "访问地址: http://<服务器IP>:7410"
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
