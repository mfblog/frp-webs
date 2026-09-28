package control

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

const defaultCommandOutputLimit = 64 << 10

// CommandRunner 封装外部命令执行，便于为 systemctl、journalctl 和 frpc 提供统一超时。
type CommandRunner interface {
	Run(ctx context.Context, name string, args ...string) (string, error)
}

type ExecRunner struct {
	Timeout     time.Duration
	OutputLimit int
}

func (r ExecRunner) Run(ctx context.Context, name string, args ...string) (string, error) {
	timeout := r.Timeout
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	limit := r.OutputLimit
	if limit <= 0 {
		limit = defaultCommandOutputLimit
	}

	commandCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	output := &limitedBuffer{limit: limit}
	cmd := exec.CommandContext(commandCtx, name, args...)
	cmd.Stdout = output
	cmd.Stderr = output
	err := cmd.Run()
	text := strings.TrimSpace(output.String())
	if errors.Is(commandCtx.Err(), context.DeadlineExceeded) {
		return text, fmt.Errorf("命令执行超时（%s）", timeout)
	}
	if err != nil {
		return text, err
	}
	return text, nil
}

type limitedBuffer struct {
	bytes.Buffer
	limit int
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	originalLength := len(p)
	remaining := b.limit - b.Len()
	if remaining > 0 {
		if len(p) > remaining {
			p = p[:remaining]
		}
		_, _ = b.Buffer.Write(p)
	}
	return originalLength, nil
}
