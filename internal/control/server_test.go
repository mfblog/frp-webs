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

func TestAuthenticationFlowAndCookieAttributes(t *testing.T) {
	runner := runnerFunc(func(context.Context, string, ...string) (string, error) {
		return "inactive", errors.New("inactive")
	})
	server := &Server{Token: "secret", Service: SystemService{Runner: runner, Name: "frpc.service"}, FRPCBin: "/bin/frpc", ConfigPath: "/tmp/frpc.toml"}
	handler := server.Handler()

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/api/status", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status = %d", unauthorized.Code)
	}

	wrong := httptest.NewRecorder()
	wrongRequest := httptest.NewRequest(http.MethodPost, "/api/session", strings.NewReader(`{"token":"wrong"}`))
	wrongRequest.Header.Set("Content-Type", "application/json")
	handler.ServeHTTP(wrong, wrongRequest)
	if wrong.Code != http.StatusUnauthorized {
		t.Fatalf("wrong token status = %d", wrong.Code)
	}

	login := httptest.NewRecorder()
	loginRequest := httptest.NewRequest(http.MethodPost, "/api/session", strings.NewReader(`{"token":"secret"}`))
	loginRequest.Header.Set("Content-Type", "application/json")
	handler.ServeHTTP(login, loginRequest)
	if login.Code != http.StatusOK {
		t.Fatalf("login status = %d body=%s", login.Code, login.Body.String())
	}
	cookies := login.Result().Cookies()
	if len(cookies) != 1 || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatalf("login cookies = %#v", cookies)
	}

	authorized := httptest.NewRecorder()
	authorizedRequest := httptest.NewRequest(http.MethodGet, "/api/status", nil)
	authorizedRequest.AddCookie(cookies[0])
	handler.ServeHTTP(authorized, authorizedRequest)
	if authorized.Code != http.StatusOK {
		t.Fatalf("authorized status = %d body=%s", authorized.Code, authorized.Body.String())
	}
}

func TestWriteRejectsCrossSiteRequest(t *testing.T) {
	server := &Server{}
	handler := server.Handler()
	request := httptest.NewRequest(http.MethodPost, "/api/session", strings.NewReader(`{"token":""}`))
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
	request := httptest.NewRequest(http.MethodPost, "/api/session", bytes.NewReader(body))
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
