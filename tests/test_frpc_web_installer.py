import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALL_SCRIPT = REPO_ROOT / "install_frp.sh"


def script_source() -> str:
    return INSTALL_SCRIPT.read_text(encoding="utf-8")


def extract_shell_function(name: str, next_name: str) -> str:
    source = script_source()
    start_marker = f"{name}() {{\n"
    end_marker = f"\n{next_name}() {{\n"
    try:
        start = source.index(start_marker)
        end = source.index(end_marker, start)
    except ValueError as error:
        raise AssertionError(f"无法提取 Shell 函数 {name}") from error
    return source[start:end]


class FrpcWebInstallerTest(unittest.TestCase):
    def run_bash(self, source: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-c", source],
            text=True,
            capture_output=True,
            check=False,
        )

    def run_install_frpc(self, config_state: str) -> list[str]:
        function_source = extract_shell_function("install_frpc", "update_frps")
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            frpc_dir = root / "frpc"
            frpc_dir.mkdir()
            if config_state != "missing":
                (frpc_dir / "frpc.toml").write_text("mock = true\n", encoding="utf-8")
            call_log = root / "calls.log"
            verify_result = "0" if config_state != "invalid" else "1"
            shell = f"""
set -euo pipefail
FRPC_DIR={str(frpc_dir)!r}
FRPC_SERVICE={str(root / 'frpc.service')!r}
FRPC_WEB_SERVICE={str(root / 'frpc-web.service')!r}
CALL_LOG={str(call_log)!r}
log_call() {{ printf '%s\n' "$1" >>"${{CALL_LOG}}"; }}
detect_arch() {{ printf '%s\n' amd64; }}
backup_file() {{ :; }}
download_release_bundle() {{ log_call "download:$1:$2"; }}
install_release_binary() {{ log_call "install:$1:$2"; }}
write_frpc_service() {{ log_call write-frpc-service; }}
is_service_registered() {{ return 1; }}
verify_config_with_binary() {{ log_call verify-config; return {verify_result}; }}
setup_frpc_web_panel() {{ log_call setup-web; }}
enable_service() {{ log_call "enable:$1"; }}
systemctl() {{ log_call "systemctl:$*"; }}
{function_source}
install_frpc
"""
            result = self.run_bash(shell)
            self.assertEqual(0, result.returncode, result.stderr)
            return call_log.read_text(encoding="utf-8").splitlines()

    def test_old_embedded_python_and_html_are_removed(self) -> None:
        source = script_source()
        self.assertNotIn("frpc_web.py", source)
        self.assertNotIn("#!/usr/bin/env python3", source)
        self.assertNotIn('cat >"${FRPC_WEB_DIR}/index.html"', source)
        self.assertNotIn("python3", extract_shell_function("install_dependencies", "detect_arch"))

    def test_web_console_service_uses_binary_and_all_interfaces(self) -> None:
        function_source = extract_shell_function("write_frpc_web_service", "setup_frpc_web_panel")
        self.assertIn("ExecStart=${FRPC_WEB_BINARY} --listen 0.0.0.0:7410", function_source)
        self.assertIn("EnvironmentFile=${FRPC_WEB_ENV}", function_source)
        self.assertNotIn("127.0.0.1", function_source)

    def test_release_download_requires_checksum(self) -> None:
        function_source = extract_shell_function("download_frpc_web_binary", "write_frpc_web_env")
        self.assertIn('checksum_name="SHA256SUMS"', function_source)
        self.assertIn("sha256sum", function_source)
        self.assertIn("拒绝安装未经校验", function_source)
        self.assertIn('asset_name="frpc-web-linux-${arch}"', function_source)

    def test_setup_downloads_binary_and_enables_service(self) -> None:
        function_source = extract_shell_function("setup_frpc_web_panel", "enable_service")
        self.assertIn('download_frpc_web_binary "${arch}"', function_source)
        self.assertIn("write_frpc_web_env", function_source)
        self.assertIn("write_frpc_web_service", function_source)
        self.assertIn('enable_service "frpc-web.service"', function_source)
        self.assertIn("监听地址: 0.0.0.0:7410", function_source)

    def test_existing_token_is_preserved(self) -> None:
        env_function = extract_shell_function("write_frpc_web_env", "apply_frpc_web_env")
        apply_function = extract_shell_function("apply_frpc_web_env", "write_frpc_web_service")
        with tempfile.TemporaryDirectory() as temp_dir:
            env_path = Path(temp_dir) / "frpc-web.env"
            token = "0123456789abcdef01234567"
            env_path.write_text(f"FRPC_WEB_TOKEN={token}\n", encoding="utf-8")
            shell = f"""
set -euo pipefail
FRPC_WEB_ENV={str(env_path)!r}
FRPC_WEB_ACCESS_TOKEN=""
random_token() {{ printf '%s\n' ffffffffffffffffffffffff; }}
{env_function}
{apply_function}
write_frpc_web_env
printf '%s\n' "${{FRPC_WEB_ACCESS_TOKEN}}"
"""
            result = self.run_bash(shell)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(token, result.stdout.strip())
            self.assertEqual(f"FRPC_WEB_TOKEN={token}\n", env_path.read_text(encoding="utf-8"))
            self.assertEqual(0o600, env_path.stat().st_mode & 0o777)

    def test_install_without_config_deploys_web_without_starting_frpc(self) -> None:
        calls = self.run_install_frpc("missing")
        self.assertIn("setup-web", calls)
        self.assertIn("systemctl:disable frpc.service", calls)
        self.assertNotIn("enable:frpc.service", calls)
        self.assertNotIn("verify-config", calls)

    def test_install_with_valid_config_deploys_web_before_starting_frpc(self) -> None:
        calls = self.run_install_frpc("valid")
        self.assertIn("verify-config", calls)
        self.assertLess(calls.index("setup-web"), calls.index("enable:frpc.service"))

    def test_install_with_invalid_config_keeps_frpc_disabled(self) -> None:
        calls = self.run_install_frpc("invalid")
        self.assertIn("verify-config", calls)
        self.assertIn("setup-web", calls)
        self.assertIn("systemctl:disable frpc.service", calls)
        self.assertNotIn("enable:frpc.service", calls)

    def test_web_download_failure_happens_before_existing_frpc_is_stopped(self) -> None:
        function_source = extract_shell_function("install_frpc", "update_frps")
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            frpc_dir = root / "frpc"
            frpc_dir.mkdir()
            (frpc_dir / "frpc.toml").write_text("mock = true\n", encoding="utf-8")
            call_log = root / "calls.log"
            shell = f"""
set -euo pipefail
FRPC_DIR={str(frpc_dir)!r}
FRPC_SERVICE={str(root / 'frpc.service')!r}
FRPC_WEB_SERVICE={str(root / 'frpc-web.service')!r}
CALL_LOG={str(call_log)!r}
log_call() {{ printf '%s\n' "$1" >>"${{CALL_LOG}}"; }}
detect_arch() {{ printf '%s\n' amd64; }}
backup_file() {{ :; }}
download_release_bundle() {{ :; }}
install_release_binary() {{ :; }}
write_frpc_service() {{ :; }}
verify_config_with_binary() {{ return 0; }}
setup_frpc_web_panel() {{ log_call setup-web-failed; return 1; }}
is_service_registered() {{ return 0; }}
enable_service() {{ log_call "enable:$1"; }}
systemctl() {{ log_call "systemctl:$*"; }}
{function_source}
install_frpc
"""
            result = self.run_bash(shell)
            self.assertNotEqual(0, result.returncode)
            calls = call_log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(["setup-web-failed"], calls)

    def test_update_install_failure_restores_previous_service_state(self) -> None:
        function_source = extract_shell_function("update_frpc", "uninstall_frps")
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            frpc_dir = root / "frpc"
            frpc_dir.mkdir()
            frpc_bin = frpc_dir / "frpc"
            frpc_bin.write_text("mock", encoding="utf-8")
            frpc_bin.chmod(0o755)
            (frpc_dir / "frpc.toml").write_text("mock = true\n", encoding="utf-8")
            call_log = root / "calls.log"
            shell = f"""
set -euo pipefail
FRPC_DIR={str(frpc_dir)!r}
FRPC_SERVICE={str(root / 'frpc.service')!r}
RELEASE_EXTRACT_DIR={str(root / 'release')!r}
CALL_LOG={str(call_log)!r}
log_call() {{ printf '%s\n' "$1" >>"${{CALL_LOG}}"; }}
detect_arch() {{ printf '%s\n' amd64; }}
download_release_bundle() {{ :; }}
verify_config_with_binary() {{ :; }}
create_runtime_backup() {{ printf '%s\n' {str(root / 'backup')!r}; }}
is_service_registered() {{ return 0; }}
install_release_binary() {{ return 1; }}
restore_runtime_backup() {{ log_call restore-binary; }}
restore_service_state() {{ log_call "restore-state:$1:$2:$3"; }}
systemctl() {{
  case "$1:$2" in
    is-active:frpc.service) printf '%s\n' active ;;
    is-enabled:frpc.service) printf '%s\n' enabled ;;
    stop:frpc.service) log_call stop-frpc ;;
  esac
}}
{function_source}
update_frpc
"""
            result = self.run_bash(shell)
            self.assertNotEqual(0, result.returncode)
            calls = call_log.read_text(encoding="utf-8").splitlines()
            self.assertIn("stop-frpc", calls)
            self.assertIn("restore-binary", calls)
            self.assertIn("restore-state:frpc.service:active:enabled", calls)


if __name__ == "__main__":
    unittest.main()
