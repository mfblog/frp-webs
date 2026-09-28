package control

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type DiscoverOptions struct {
	FRPCBin    string
	ConfigPath string
	Service    string
}

type Paths struct {
	FRPCBin    string
	ConfigPath string
}

type LookPathFunc func(string) (string, error)

func Discover(ctx context.Context, runner CommandRunner, options DiscoverOptions, lookPath LookPathFunc) (Paths, error) {
	return discover(ctx, runner, options, lookPath, func(path string) bool {
		info, err := os.Stat(path)
		return err == nil && !info.IsDir()
	})
}

func discover(ctx context.Context, runner CommandRunner, options DiscoverOptions, lookPath LookPathFunc, fileExists func(string) bool) (Paths, error) {
	service := options.Service
	if service == "" {
		service = "frpc.service"
	}

	var serviceBin, serviceConfig string
	if options.FRPCBin == "" || options.ConfigPath == "" {
		output, _ := runner.Run(ctx, "systemctl", "show", service, "--property=ExecStart", "--value")
		serviceBin, serviceConfig = parseExecStart(output)
	}

	bin := options.FRPCBin
	if bin == "" {
		bin = serviceBin
	}
	if bin == "" {
		const defaultBin = "/usr/local/frpc/frpc"
		if fileExists(defaultBin) {
			bin = defaultBin
		}
	}
	if bin == "" {
		if lookPath == nil {
			return Paths{}, fmt.Errorf("未找到 frpc：请使用 --frpc-bin 指定路径")
		}
		resolved, err := lookPath("frpc")
		if err != nil {
			return Paths{}, fmt.Errorf("未找到 frpc：请使用 --frpc-bin 指定路径: %w", err)
		}
		bin = resolved
	}

	configPath := options.ConfigPath
	if configPath == "" {
		configPath = serviceConfig
	}
	if configPath == "" {
		configPath = filepath.Join(filepath.Dir(bin), "frpc.toml")
	}

	return Paths{FRPCBin: filepath.Clean(bin), ConfigPath: filepath.Clean(configPath)}, nil
}

func parseExecStart(value string) (string, string) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", ""
	}
	if index := strings.Index(value, "argv[]="); index >= 0 {
		value = value[index+len("argv[]="):]
		if end := strings.Index(value, " ;"); end >= 0 {
			value = value[:end]
		}
	}
	tokens := splitCommandLine(value)
	if len(tokens) == 0 {
		return "", ""
	}

	binIndex := -1
	for index, token := range tokens {
		cleaned := strings.TrimPrefix(token, "path=")
		if filepath.Base(cleaned) == "frpc" {
			tokens[index] = cleaned
			binIndex = index
			break
		}
	}
	if binIndex < 0 {
		return "", ""
	}

	var config string
	for index := binIndex + 1; index < len(tokens); index++ {
		switch {
		case tokens[index] == "-c" || tokens[index] == "--config":
			if index+1 < len(tokens) {
				config = tokens[index+1]
			}
		case strings.HasPrefix(tokens[index], "--config="):
			config = strings.TrimPrefix(tokens[index], "--config=")
		}
		if config != "" {
			break
		}
	}
	return tokens[binIndex], config
}

func splitCommandLine(value string) []string {
	var tokens []string
	var current strings.Builder
	var quote rune
	escaped := false
	flush := func() {
		if current.Len() > 0 {
			tokens = append(tokens, current.String())
			current.Reset()
		}
	}

	for _, char := range value {
		if escaped {
			current.WriteRune(char)
			escaped = false
			continue
		}
		if char == '\\' && quote != '\'' {
			escaped = true
			continue
		}
		if quote != 0 {
			if char == quote {
				quote = 0
			} else {
				current.WriteRune(char)
			}
			continue
		}
		switch char {
		case '\'', '"':
			quote = char
		case ' ', '\t', '\r', '\n', ';', '{', '}':
			flush()
		default:
			current.WriteRune(char)
		}
	}
	if escaped {
		current.WriteRune('\\')
	}
	flush()
	return tokens
}
