package control

import (
	"context"
	"errors"
	"testing"
)

type runnerFunc func(context.Context, string, ...string) (string, error)

func (f runnerFunc) Run(ctx context.Context, name string, args ...string) (string, error) {
	return f(ctx, name, args...)
}

func TestDiscoverPriority(t *testing.T) {
	tests := []struct {
		name       string
		options    DiscoverOptions
		execStart  string
		lookPath   LookPathFunc
		wantBin    string
		wantConfig string
	}{
		{
			name:       "显式参数优先于systemd",
			options:    DiscoverOptions{FRPCBin: "/opt/custom/frpc", ConfigPath: "/etc/custom.toml", Service: "frpc.service"},
			execStart:  "/system/frpc -c /system/frpc.toml",
			wantBin:    "/opt/custom/frpc",
			wantConfig: "/etc/custom.toml",
		},
		{
			name:       "解析systemctl show结构",
			options:    DiscoverOptions{Service: "frpc.service"},
			execStart:  "{ path=/srv/frpc/frpc ; argv[]=/srv/frpc/frpc -c /srv/frpc/client.toml ; ignore_errors=no ; }",
			wantBin:    "/srv/frpc/frpc",
			wantConfig: "/srv/frpc/client.toml",
		},
		{
			name:       "默认安装路径优先于PATH",
			options:    DiscoverOptions{Service: "missing.service"},
			lookPath:   func(string) (string, error) { return "/opt/bin/frpc", nil },
			wantBin:    "/usr/local/frpc/frpc",
			wantConfig: "/usr/local/frpc/frpc.toml",
		},
		{
			name:       "PATH二进制并推导同目录配置",
			options:    DiscoverOptions{Service: "missing.service"},
			lookPath:   func(string) (string, error) { return "/opt/bin/frpc", nil },
			wantBin:    "/opt/bin/frpc",
			wantConfig: "/opt/bin/frpc.toml",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			runner := runnerFunc(func(context.Context, string, ...string) (string, error) {
				return test.execStart, nil
			})
			lookPath := test.lookPath
			if lookPath == nil {
				lookPath = func(string) (string, error) { return "", errors.New("不应调用 PATH") }
			}
			defaultExists := test.name == "默认安装路径优先于PATH"
			paths, err := discover(context.Background(), runner, test.options, lookPath, func(string) bool { return defaultExists })
			if err != nil {
				t.Fatalf("Discover() error = %v", err)
			}
			if paths.FRPCBin != test.wantBin || paths.ConfigPath != test.wantConfig {
				t.Fatalf("Discover() = %#v, want bin=%q config=%q", paths, test.wantBin, test.wantConfig)
			}
		})
	}
}

func TestParseExecStartQuotedConfig(t *testing.T) {
	bin, config := parseExecStart(`/usr/local/frpc/frpc --config="/etc/frpc/client config.toml"`)
	if bin != "/usr/local/frpc/frpc" || config != "/etc/frpc/client config.toml" {
		t.Fatalf("parseExecStart() = %q, %q", bin, config)
	}
}
