package control

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type verifierFunc func(context.Context, string) error

func (f verifierFunc) Verify(ctx context.Context, content string) error { return f(ctx, content) }

type fakeService struct {
	state           ServiceState
	restartErr      error
	restartCalls    int
	enabledRestored []bool
	activeRestored  []bool
}

func (s *fakeService) State(context.Context) ServiceState { return s.state }
func (s *fakeService) Restart(context.Context) error {
	s.restartCalls++
	return s.restartErr
}
func (s *fakeService) SetEnabled(_ context.Context, enabled bool) error {
	s.enabledRestored = append(s.enabledRestored, enabled)
	return nil
}
func (s *fakeService) RestoreRunning(_ context.Context, active bool) error {
	s.activeRestored = append(s.activeRestored, active)
	return nil
}

func TestConfigManagerRejectsRevisionConflict(t *testing.T) {
	path := filepath.Join(t.TempDir(), "frpc.toml")
	if err := os.WriteFile(path, []byte("old = true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	service := &fakeService{}
	manager := &ConfigManager{Path: path, Verifier: verifierFunc(func(context.Context, string) error { return nil }), Service: service}
	stale := "stale"

	_, err := manager.Apply(context.Background(), ApplyRequest{Content: "new = true\n", Restart: true, Revision: &stale})
	if !errors.Is(err, ErrRevisionConflict) {
		t.Fatalf("Apply() error = %v, want revision conflict", err)
	}
	content, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if string(content) != "old = true\n" || service.restartCalls != 0 {
		t.Fatalf("冲突后发生副作用: content=%q restartCalls=%d", content, service.restartCalls)
	}
}

func TestConfigManagerAtomicSaveUsesPrivateMode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "frpc.toml")
	manager := &ConfigManager{Path: path, Verifier: verifierFunc(func(context.Context, string) error { return nil })}

	result, err := manager.Apply(context.Background(), ApplyRequest{Content: "serverAddr = \"example.invalid\"\n"})
	if err != nil {
		t.Fatalf("Apply() error = %v", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %o, want 600", info.Mode().Perm())
	}
	if !result.Exists || result.Revision == nil {
		t.Fatalf("Apply() result = %#v", result)
	}
}

func TestConfigManagerFirstStartFailureRemovesNewConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "frpc.toml")
	service := &fakeService{state: ServiceState{}, restartErr: errors.New("boom")}
	manager := &ConfigManager{Path: path, Verifier: verifierFunc(func(context.Context, string) error { return nil }), Service: service}

	result, err := manager.Apply(context.Background(), ApplyRequest{Content: "serverAddr = \"example.invalid\"\n", Restart: true})
	if err == nil || result.Exists {
		t.Fatalf("Apply() result=%#v error=%v, want rollback failure result", result, err)
	}
	if _, statErr := os.Stat(path); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("新配置未删除: %v", statErr)
	}
	if len(service.enabledRestored) != 1 || service.enabledRestored[0] || len(service.activeRestored) != 1 || service.activeRestored[0] {
		t.Fatalf("服务状态未恢复: enabled=%v active=%v", service.enabledRestored, service.activeRestored)
	}
}

func TestConfigManagerExistingRestartFailureRollsBack(t *testing.T) {
	path := filepath.Join(t.TempDir(), "frpc.toml")
	if err := os.WriteFile(path, []byte("old = true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	managerSnapshot, err := readSnapshot(path)
	if err != nil {
		t.Fatal(err)
	}
	service := &fakeService{state: ServiceState{Active: true, Enabled: true}, restartErr: errors.New("boom")}
	manager := &ConfigManager{Path: path, Verifier: verifierFunc(func(context.Context, string) error { return nil }), Service: service}

	_, err = manager.Apply(context.Background(), ApplyRequest{Content: "new = true\n", Restart: true, Revision: managerSnapshot.Revision})
	if err == nil {
		t.Fatal("Apply() error = nil, want restart failure")
	}
	content, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if string(content) != "old = true\n" {
		t.Fatalf("回滚内容 = %q", content)
	}
	if len(service.enabledRestored) != 1 || !service.enabledRestored[0] || len(service.activeRestored) != 1 || !service.activeRestored[0] {
		t.Fatalf("服务状态未恢复: enabled=%v active=%v", service.enabledRestored, service.activeRestored)
	}
}
