package main

import (
	"context"
	"embed"
	"flag"
	"io/fs"
	"log"
	"net/http"
	"os/exec"
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
	flag.Parse()

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
		Static:     staticRoot,
		Config:     manager,
		Service:    service,
		FRPCBin:    paths.FRPCBin,
		ConfigPath: paths.ConfigPath,
		Updater: &control.Updater{
			Runner: runner, Service: service, Bin: paths.FRPCBin, ConfigPath: paths.ConfigPath, Config: manager,
		},
	}

	httpServer := &http.Server{
		Addr:              *listen,
		Handler:           application.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       20 * time.Second,
		WriteTimeout:      3 * time.Minute,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("frpc Web 控制台监听 %s（frpc=%s，config=%s）", *listen, paths.FRPCBin, paths.ConfigPath)
	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
