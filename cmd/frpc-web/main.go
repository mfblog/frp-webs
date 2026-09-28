package main

import (
	"context"
	"embed"
	"flag"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"frpc-web/internal/control"
)

//go:embed static
var staticFiles embed.FS

func main() {
	listen := flag.String("listen", "0.0.0.0:7410", "HTTP 监听地址")
	frpcBin := flag.String("frpc-bin", "", "frpc 二进制路径")
	frpcConfig := flag.String("frpc-config", "", "frpc 配置文件路径")
	frpcService := flag.String("frpc-service", "frpc.service", "systemd 服务名")
	authToken := flag.String("auth-token", os.Getenv("FRPC_WEB_TOKEN"), "控制台认证令牌（也可使用 FRPC_WEB_TOKEN）")
	allowUnauthenticated := flag.Bool("allow-unauthenticated", false, "允许非本机地址免登录访问（仅限可信内网）")
	flag.Parse()
	if rejectsMissingAuthentication(*listen, *authToken, *allowUnauthenticated) {
		log.Fatal("非本机监听必须配置 --auth-token 或 FRPC_WEB_TOKEN")
	}

	runner := control.ExecRunner{Timeout: 15 * time.Second}
	paths, err := control.Discover(context.Background(), runner, control.DiscoverOptions{
		FRPCBin:    *frpcBin,
		ConfigPath: *frpcConfig,
		Service:    *frpcService,
	}, exec.LookPath)
	if err != nil {
		log.Fatal(err)
	}
	staticRoot, err := fs.Sub(staticFiles, "static")
	if err != nil {
		log.Fatal(err)
	}

	service := control.SystemService{Runner: runner, Name: *frpcService}
	manager := &control.ConfigManager{
		Path:     paths.ConfigPath,
		Verifier: control.FRPCVerifier{Runner: runner, Bin: paths.FRPCBin},
		Service:  service,
	}
	application := &control.Server{
		Token:      *authToken,
		Static:     staticRoot,
		Config:     manager,
		Service:    service,
		FRPCBin:    paths.FRPCBin,
		ConfigPath: paths.ConfigPath,
	}

	httpServer := &http.Server{
		Addr:              *listen,
		Handler:           application.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       20 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("frpc Web 控制台监听 %s（frpc=%s，config=%s）", *listen, paths.FRPCBin, paths.ConfigPath)
	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func rejectsMissingAuthentication(address, token string, allowUnauthenticated bool) bool {
	return token == "" && !allowUnauthenticated && !isLoopbackListen(address)
}

func isLoopbackListen(address string) bool {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return false
	}
	host = strings.Trim(host, "[]")
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
