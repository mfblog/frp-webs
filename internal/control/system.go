package control

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type SystemService struct {
	Runner   CommandRunner
	Name     string
	Attempts int
	Delay    time.Duration
}

func (s SystemService) State(ctx context.Context) ServiceState {
	_, activeErr := s.Runner.Run(ctx, "systemctl", "is-active", "--quiet", s.Name)
	_, enabledErr := s.Runner.Run(ctx, "systemctl", "is-enabled", "--quiet", s.Name)
	return ServiceState{Active: activeErr == nil, Enabled: enabledErr == nil}
}

func (s SystemService) Restart(ctx context.Context) error {
	wasEnabled := s.State(ctx).Enabled
	if err := s.SetEnabled(ctx, true); err != nil {
		return err
	}
	output, err := s.Runner.Run(ctx, "systemctl", "restart", s.Name)
	if err == nil {
		err = s.waitActive(ctx)
	}
	if err != nil {
		if !wasEnabled {
			_ = s.SetEnabled(ctx, false)
		}
		return commandError("启动 frpc 失败", output, err)
	}
	return nil
}

func (s SystemService) SetEnabled(ctx context.Context, enabled bool) error {
	action := "disable"
	if enabled {
		action = "enable"
	}
	output, err := s.Runner.Run(ctx, "systemctl", action, s.Name)
	if err != nil {
		return commandError("设置服务 "+action+" 状态失败", output, err)
	}
	return nil
}

func (s SystemService) RestoreRunning(ctx context.Context, active bool) error {
	action := "stop"
	if active {
		action = "restart"
	}
	output, err := s.Runner.Run(ctx, "systemctl", action, s.Name)
	if err != nil {
		return commandError("恢复服务运行状态失败", output, err)
	}
	if active {
		return s.waitActive(ctx)
	}
	return nil
}

func (s SystemService) Action(ctx context.Context, action string) error {
	wasEnabled := false
	if action == "start" || action == "restart" {
		wasEnabled = s.State(ctx).Enabled
		if err := s.SetEnabled(ctx, true); err != nil {
			return err
		}
	}
	output, err := s.Runner.Run(ctx, "systemctl", action, s.Name)
	if err != nil {
		if (action == "start" || action == "restart") && !wasEnabled {
			_ = s.SetEnabled(ctx, false)
		}
		return commandError("执行服务操作失败", output, err)
	}
	if action == "start" || action == "restart" {
		if err := s.waitActive(ctx); err != nil {
			if !wasEnabled {
				_ = s.SetEnabled(ctx, false)
			}
			return err
		}
	}
	return nil
}

func (s SystemService) Status(ctx context.Context, frpcBin, configPath string) map[string]any {
	activeOutput, activeErr := s.Runner.Run(ctx, "systemctl", "is-active", s.Name)
	enabledOutput, enabledErr := s.Runner.Run(ctx, "systemctl", "is-enabled", s.Name)
	versionOutput, versionErr := s.Runner.Run(ctx, frpcBin, "--version")
	info, statErr := os.Stat(configPath)

	active := strings.TrimSpace(activeOutput)
	if active == "" {
		if activeErr == nil {
			active = "active"
		} else {
			active = "inactive"
		}
	}
	enabled := strings.TrimSpace(enabledOutput)
	if enabled == "" {
		if enabledErr == nil {
			enabled = "enabled"
		} else {
			enabled = "disabled"
		}
	}
	version := strings.TrimSpace(versionOutput)
	if versionErr != nil || version == "" {
		version = "unknown"
	}

	status := map[string]any{
		"service":       s.Name,
		"active":        active,
		"enabled":       enabled,
		"version":       version,
		"config_exists": statErr == nil,
		"frpc_bin":      frpcBin,
		"config_path":   configPath,
		"discovery": map[string]string{
			"binary": frpcBin,
			"config": configPath,
		},
	}
	if statErr == nil {
		status["config_mtime"] = info.ModTime().Unix()
	} else {
		status["config_mtime"] = nil
	}
	return status
}

func (s SystemService) Logs(ctx context.Context, lines int) (string, error) {
	output, err := s.Runner.Run(ctx, "journalctl", "-u", s.Name, "-n", strconv.Itoa(lines), "--no-pager")
	if err != nil {
		return "", commandError("读取日志失败", output, err)
	}
	return output, nil
}

func (s SystemService) waitActive(ctx context.Context) error {
	attempts := s.Attempts
	if attempts <= 0 {
		attempts = 5
	}
	delay := s.Delay
	if delay <= 0 {
		delay = 200 * time.Millisecond
	}
	var lastOutput string
	var lastErr error
	for attempt := 0; attempt < attempts; attempt++ {
		lastOutput, lastErr = s.Runner.Run(ctx, "systemctl", "is-active", "--quiet", s.Name)
		if lastErr == nil {
			return nil
		}
		if attempt+1 < attempts {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(delay):
			}
		}
	}
	return commandError("frpc 未能稳定进入 active 状态", lastOutput, lastErr)
}

type FRPCVerifier struct {
	Runner CommandRunner
	Bin    string
}

func (v FRPCVerifier) Verify(ctx context.Context, content string) error {
	temporary, err := os.CreateTemp("", "frpc-web-*.toml")
	if err != nil {
		return fmt.Errorf("创建校验文件失败: %w", err)
	}
	path := temporary.Name()
	defer os.Remove(path)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.WriteString(content); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	output, err := v.Runner.Run(ctx, v.Bin, "verify", "-c", path)
	if err != nil {
		return commandError("配置校验失败", output, err)
	}
	return nil
}

func commandError(prefix, output string, err error) error {
	output = strings.TrimSpace(output)
	if output != "" {
		return errors.New(output)
	}
	if err != nil {
		return fmt.Errorf("%s: %w", prefix, err)
	}
	return errors.New(prefix)
}
