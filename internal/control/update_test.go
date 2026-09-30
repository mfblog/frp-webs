package control

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestCompareVersions(t *testing.T) {
	for _, test := range []struct {
		current, latest string
		want            int
	}{
		{"0.9.9", "v0.10.0", -1}, {"v1.2.3", "1.2.3", 0},
		{"1.3.0", "1.2.9", 1}, {"1.2.3-rc.1", "1.2.3", -1},
	} {
		got, err := compareVersions(test.current, test.latest)
		if err != nil || got != test.want {
			t.Errorf("compareVersions(%q,%q) = %d, %v", test.current, test.latest, got, err)
		}
	}
	if _, err := compareVersions("unknown", "1.2.3"); err == nil {
		t.Fatal("unknown version accepted")
	}
}

func TestUpdateCheckAndApply(t *testing.T) {
	if releaseArch() == "" {
		t.Skip("unsupported architecture")
	}
	dir := t.TempDir()
	binary := filepath.Join(dir, "frpc")
	if err := os.WriteFile(binary, []byte("old binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	var archive bytes.Buffer
	gz := gzip.NewWriter(&archive)
	tarWriter := tar.NewWriter(gz)
	payload := []byte("new binary")
	name := fmt.Sprintf("frp_0.99.0_linux_%s/frpc", runtime.GOARCH)
	if err := tarWriter.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(payload))}); err != nil {
		t.Fatal(err)
	}
	if _, err := tarWriter.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(archive.Bytes())
	var corrupt, active, failRestart, directFail bool
	var directAPI, directBundle, acceleratedLatest, acceleratedBundle int
	var restarts int
	var api *httptest.Server
	api = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/bundle":
			directBundle++
			if directFail {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			if corrupt {
				_, _ = w.Write([]byte("corrupt"))
			} else {
				_, _ = w.Write(archive.Bytes())
			}
			return
		case "/https://github.com/fatedier/frp/releases/latest":
			acceleratedLatest++
			http.Redirect(w, r, api.URL+"/https://github.com/fatedier/frp/releases/tag/v0.99.0", http.StatusFound)
			return
		case "/https://github.com/fatedier/frp/releases/tag/v0.99.0":
			_, _ = w.Write([]byte("release"))
			return
		case "/https://github.com/fatedier/frp/releases/download/v0.99.0/frp_sha256_checksums.txt":
			_, _ = fmt.Fprintf(w, "%s  frp_0.99.0_linux_%s.tar.gz\n", hex.EncodeToString(hash[:]), runtime.GOARCH)
			return
		case "/https://github.com/fatedier/frp/releases/download/v0.99.0/" + fmt.Sprintf("frp_0.99.0_linux_%s.tar.gz", runtime.GOARCH):
			acceleratedBundle++
			_, _ = w.Write(archive.Bytes())
			return
		}
		directAPI++
		if directFail {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		_ = json.NewEncoder(w).Encode(releaseInfo{Tag: "v0.99.0", Assets: []releaseAsset{{
			Name: fmt.Sprintf("frp_0.99.0_linux_%s.tar.gz", runtime.GOARCH),
			URL:  api.URL + "/bundle", Digest: "sha256:" + hex.EncodeToString(hash[:]),
		}}})
	}))
	defer api.Close()
	runner := runnerFunc(func(_ context.Context, command string, args ...string) (string, error) {
		if command == "systemctl" {
			if len(args) > 0 && args[0] == "is-active" && active {
				return "", nil
			}
			if len(args) > 0 && args[0] == "is-enabled" && active {
				return "", nil
			}
			if len(args) > 0 && args[0] == "stop" {
				return "", nil
			}
			if len(args) > 0 && args[0] == "restart" {
				restarts++
				if failRestart && restarts == 1 {
					return "failed", fmt.Errorf("failed")
				}
				return "", nil
			}
			return "inactive", fmt.Errorf("inactive")
		}
		if len(args) > 0 && args[0] == "--version" {
			if command == binary {
				return "0.98.0", nil
			}
			return "0.99.0", nil
		}
		return "", nil
	})
	u := &Updater{API: api.URL, Accelerator: api.URL + "/", Runner: runner, Service: SystemService{Runner: runner, Name: "frpc.service"}, Bin: binary, ConfigPath: filepath.Join(dir, "frpc.toml")}
	handler := (&Server{Updater: u}).Handler()
	request := func(method, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "/api/update", strings.NewReader(body))
		if method == http.MethodPost {
			r.Header.Set("Content-Type", "application/json")
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	if w := request(http.MethodGet, ""); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"available":true`) {
		t.Fatalf("check: %d %s", w.Code, w.Body.String())
	}
	if w := request(http.MethodPost, `{"version":"v0.99.1"}`); w.Code != http.StatusConflict {
		t.Fatalf("stale version: %d %s", w.Code, w.Body.String())
	}
	corrupt = true
	if w := request(http.MethodPost, `{"version":"v0.99.0"}`); w.Code != http.StatusInternalServerError || !strings.Contains(w.Body.String(), "SHA256") {
		t.Fatalf("bad digest: %d %s", w.Code, w.Body.String())
	}
	contents, _ := os.ReadFile(binary)
	if string(contents) != "old binary" {
		t.Fatal("binary changed on digest failure")
	}
	corrupt = false
	if w := request(http.MethodPost, `{"version":"v0.99.0"}`); w.Code != http.StatusOK {
		t.Fatalf("update: %d %s", w.Code, w.Body.String())
	}
	contents, _ = os.ReadFile(binary)
	if string(contents) != "new binary" || acceleratedLatest != 0 || acceleratedBundle != 0 || directAPI == 0 || directBundle == 0 {
		t.Fatalf("direct update failed: binary=%q, direct API/bundle=%d/%d, accelerated=%d/%d", contents, directAPI, directBundle, acceleratedLatest, acceleratedBundle)
	}
	if err := os.WriteFile(binary, []byte("old binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	active, failRestart, directFail = true, true, true
	if w := request(http.MethodGet, ""); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"available":true`) {
		t.Fatalf("accelerated check: %d %s", w.Code, w.Body.String())
	}
	w := request(http.MethodPost, `{"version":"v0.99.0"}`)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("failed restart: %d %s", w.Code, w.Body.String())
	}
	contents, _ = os.ReadFile(binary)
	if string(contents) != "old binary" || restarts != 2 || acceleratedLatest == 0 || acceleratedBundle == 0 {
		t.Fatalf("accelerated rollback failed: binary=%q, restarts=%d, accelerated=%d/%d, response=%s", contents, restarts, acceleratedLatest, acceleratedBundle, w.Body.String())
	}
}

func TestUpdateRejectsCrossSite(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/api/update", strings.NewReader(`{"version":"1.0.0"}`))
	request.Header.Set("Sec-Fetch-Site", "cross-site")
	response := httptest.NewRecorder()
	(&Server{Updater: &Updater{}}).Handler().ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("status = %d", response.Code)
	}
}
