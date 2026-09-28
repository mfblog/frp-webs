package control

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAPIsAreAccessibleWithoutAuthentication(t *testing.T) {
	runner := runnerFunc(func(_ context.Context, command string, _ ...string) (string, error) {
		if command == "systemctl" {
			return "inactive", errors.New("inactive")
		}
		if command == "journalctl" {
			return "test logs", nil
		}
		return "0.68.1", nil
	})
	server := &Server{
		Service:    SystemService{Runner: runner, Name: "frpc.service"},
		FRPCBin:    "/bin/frpc",
		ConfigPath: filepath.Join(t.TempDir(), "frpc.toml"),
		Config: &ConfigManager{
			Path: filepath.Join(t.TempDir(), "frpc.toml"),
			Verifier: verifierFunc(func(context.Context, string) error {
				return nil
			}),
		},
	}
	handler := server.Handler()

	for _, path := range []string{"/api/status", "/api/config", "/api/logs?lines=10", "/api/verify"} {
		t.Run(path, func(t *testing.T) {
			method := http.MethodGet
			var body *strings.Reader
			if path == "/api/verify" {
				method = http.MethodPost
				body = strings.NewReader(`{"content":"valid = true"}`)
			}
			response := httptest.NewRecorder()
			var request *http.Request
			if body == nil {
				request = httptest.NewRequest(method, path, nil)
			} else {
				request = httptest.NewRequest(method, path, body)
				request.Header.Set("Content-Type", "application/json")
			}
			handler.ServeHTTP(response, request)
			if response.Code == http.StatusUnauthorized {
				t.Fatalf("request unexpectedly required authentication: %s", response.Body.String())
			}
			if response.Code != http.StatusOK {
				t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
			}
		})
	}

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/api/session", nil))
	if response.Code != http.StatusNotFound {
		t.Fatalf("removed session API status = %d body=%s", response.Code, response.Body.String())
	}
}

func TestWriteRejectsCrossSiteRequest(t *testing.T) {
	server := &Server{}
	handler := server.Handler()
	request := httptest.NewRequest(http.MethodPost, "/api/verify", strings.NewReader(`{"content":"valid = true"}`))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Sec-Fetch-Site", "cross-site")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
}

func TestJSONRequestBodyLimit(t *testing.T) {
	server := &Server{}
	handler := server.Handler()
	body := bytes.Repeat([]byte("x"), MaxRequestBody+1)
	request := httptest.NewRequest(http.MethodPost, "/api/config", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
}

func TestConfigResponseUsesContractFieldNames(t *testing.T) {
	encoded, err := json.Marshal(Snapshot{Content: "x", Exists: true})
	if err != nil {
		t.Fatal(err)
	}
	text := string(encoded)
	if !strings.Contains(text, `"content"`) || strings.Contains(text, `"Content"`) {
		t.Fatalf("JSON = %s", text)
	}
}

func TestServiceStartVerifiesCurrentConfigBeforeSystemctl(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "frpc.toml")
	if err := os.WriteFile(configPath, []byte("invalid = true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	commandCalled := false
	runner := runnerFunc(func(context.Context, string, ...string) (string, error) {
		commandCalled = true
		return "", nil
	})
	manager := &ConfigManager{
		Path: configPath,
		Verifier: verifierFunc(func(context.Context, string) error {
			return errors.New("配置校验失败")
		}),
	}
	server := &Server{Config: manager, ConfigPath: configPath, Service: SystemService{Runner: runner, Name: "frpc.service"}}
	request := httptest.NewRequest(http.MethodPost, "/api/service", strings.NewReader(`{"action":"start"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	server.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	if commandCalled {
		t.Fatal("配置校验失败后仍调用了 systemctl")
	}
}

func TestUnknownAPIUsesJSON404(t *testing.T) {
	server := &Server{}
	response := httptest.NewRecorder()
	server.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/unknown", nil))

	if response.Code != http.StatusNotFound {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	if contentType := response.Header().Get("Content-Type"); !strings.HasPrefix(contentType, "application/json") {
		t.Fatalf("Content-Type = %q", contentType)
	}
}
