package control

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const MaxConfigSize = 1 << 20

var ErrRevisionConflict = errors.New("配置文件已被其他操作修改，请刷新后合并变更")

type Snapshot struct {
	Content  string  `json:"content"`
	Exists   bool    `json:"exists"`
	Revision *string `json:"revision"`
}

type ApplyRequest struct {
	Content  string  `json:"content"`
	Restart  bool    `json:"restart"`
	Revision *string `json:"revision"`
}

type ApplyResult struct {
	Revision *string `json:"revision"`
	Exists   bool    `json:"exists"`
	Message  string  `json:"-"`
}

type ServiceState struct {
	Active  bool
	Enabled bool
}

type ServiceController interface {
	State(ctx context.Context) ServiceState
	Restart(ctx context.Context) error
	SetEnabled(ctx context.Context, enabled bool) error
	RestoreRunning(ctx context.Context, active bool) error
}

type Verifier interface {
	Verify(ctx context.Context, content string) error
}

type ConfigManager struct {
	Path     string
	Verifier Verifier
	Service  ServiceController
	mu       sync.Mutex
}

func (m *ConfigManager) Read() (Snapshot, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return readSnapshot(m.Path)
}

func (m *ConfigManager) Apply(ctx context.Context, request ApplyRequest) (ApplyResult, error) {
	if strings.TrimSpace(request.Content) == "" {
		return ApplyResult{}, errors.New("配置内容不能为空")
	}
	if len(request.Content) > MaxConfigSize {
		return ApplyResult{}, errors.New("配置内容超过 1 MiB 限制")
	}
	if m.Verifier == nil {
		return ApplyResult{}, errors.New("配置校验器未初始化")
	}
	if err := m.Verifier.Verify(ctx, request.Content); err != nil {
		return ApplyResult{}, err
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	previous, err := readSnapshot(m.Path)
	if err != nil {
		return ApplyResult{}, err
	}
	if !sameRevision(request.Revision, previous.Revision) {
		return ApplyResult{}, ErrRevisionConflict
	}

	state := ServiceState{}
	if request.Restart {
		if m.Service == nil {
			return ApplyResult{}, errors.New("服务控制器未初始化")
		}
		state = m.Service.State(ctx)
	}
	if previous.Exists {
		if err := writeBackup(m.Path, previous.Content); err != nil {
			return ApplyResult{}, fmt.Errorf("备份旧配置失败: %w", err)
		}
	}

	currentRevision, err := statRevision(m.Path)
	if err != nil {
		return ApplyResult{}, err
	}
	if !sameRevision(previous.Revision, currentRevision) {
		return ApplyResult{}, errors.New("配置文件已在保存过程中发生变化，请刷新后重试")
	}
	if err := writeFileAtomic(m.Path, request.Content, 0o600); err != nil {
		return ApplyResult{}, fmt.Errorf("写入配置失败: %w", err)
	}

	if !request.Restart {
		return currentApplyResult(m.Path, "配置已保存")
	}
	if err := m.Service.Restart(ctx); err == nil {
		action := "启动"
		if state.Active {
			action = "重启"
		}
		return currentApplyResult(m.Path, "配置已保存，frpc 已"+action)
	} else {
		rollbackMessage := m.rollback(ctx, previous, state)
		result, resultErr := currentApplyResult(m.Path, "")
		if resultErr != nil {
			return ApplyResult{}, fmt.Errorf("frpc 启动失败: %v；%s；读取回滚结果失败: %w", err, rollbackMessage, resultErr)
		}
		result.Message = fmt.Sprintf("frpc 启动失败: %v，%s", err, rollbackMessage)
		return result, errors.New(result.Message)
	}
}

func (m *ConfigManager) rollback(ctx context.Context, previous Snapshot, state ServiceState) string {
	notes := make([]string, 0, 3)
	if previous.Exists {
		if err := writeFileAtomic(m.Path, previous.Content, 0o600); err != nil {
			notes = append(notes, "回滚旧配置失败: "+err.Error())
		} else {
			notes = append(notes, "已回滚到上一份配置")
		}
	} else {
		if err := os.Remove(m.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
			notes = append(notes, "删除新配置失败: "+err.Error())
		} else {
			notes = append(notes, "已移除本次新建的配置")
		}
	}
	if err := m.Service.SetEnabled(ctx, state.Enabled); err != nil {
		notes = append(notes, "恢复服务启用状态失败: "+err.Error())
	}
	if err := m.Service.RestoreRunning(ctx, state.Active); err != nil {
		notes = append(notes, "恢复服务运行状态失败: "+err.Error())
	} else if state.Active {
		notes = append(notes, "服务已恢复")
	}
	return strings.Join(notes, "，")
}

func readSnapshot(path string) (Snapshot, error) {
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return Snapshot{}, nil
	}
	if err != nil {
		return Snapshot{}, err
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return Snapshot{}, err
	}
	if info.Size() > MaxConfigSize {
		return Snapshot{}, errors.New("磁盘配置超过 1 MiB 限制")
	}
	content, err := io.ReadAll(io.LimitReader(file, MaxConfigSize+1))
	if err != nil {
		return Snapshot{}, err
	}
	revision := revisionFromInfo(info)
	return Snapshot{Content: string(content), Exists: true, Revision: &revision}, nil
}

func statRevision(path string) (*string, error) {
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	revision := revisionFromInfo(info)
	return &revision, nil
}

func revisionFromInfo(info os.FileInfo) string {
	return strconv.FormatInt(info.ModTime().UnixNano(), 10) + ":" + strconv.FormatInt(info.Size(), 10)
}

func sameRevision(left, right *string) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return *left == *right
}

func writeBackup(path, content string) error {
	stamp := time.Now().Format("20060102150405.000000000")
	return writeFileAtomic(path+".bak."+stamp, content, 0o600)
}

func writeFileAtomic(path, content string, mode os.FileMode) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)

	if err := temporary.Chmod(mode); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := io.WriteString(temporary, content); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	if directoryHandle, err := os.Open(directory); err == nil {
		defer directoryHandle.Close()
		if err := directoryHandle.Sync(); err != nil {
			return err
		}
	}
	return nil
}

func currentApplyResult(path, message string) (ApplyResult, error) {
	revision, err := statRevision(path)
	if err != nil {
		return ApplyResult{}, err
	}
	return ApplyResult{Revision: revision, Exists: revision != nil, Message: message}, nil
}
