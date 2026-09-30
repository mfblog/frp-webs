package control

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

const releaseAPI = "https://api.github.com/repos/fatedier/frp/releases/latest"
const githubAccelerator = "https://ghfast.top/"
const githubRelease = "https://github.com/fatedier/frp/releases/"
const maxReleaseSize = 100 << 20

var versionPattern = regexp.MustCompile(`^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$`)

type releaseAsset struct {
	Name   string `json:"name"`
	URL    string `json:"browser_download_url"`
	Digest string `json:"digest"`
}

type releaseInfo struct {
	Tag    string         `json:"tag_name"`
	Assets []releaseAsset `json:"assets"`
}

type UpdateInfo struct {
	Current   string `json:"current"`
	Latest    string `json:"latest"`
	Available bool   `json:"available"`
}

type Updater struct {
	Client      *http.Client
	Runner      CommandRunner
	Service     SystemService
	Bin         string
	ConfigPath  string
	Config      *ConfigManager
	API         string // 测试时可使用本地 Release API
	Accelerator string // 测试时可使用本地加速服务
	mu          sync.Mutex
}

func compareVersions(current, latest string) (int, error) {
	left, right := versionPattern.FindStringSubmatch(strings.TrimSpace(current)), versionPattern.FindStringSubmatch(strings.TrimSpace(latest))
	if left == nil || right == nil {
		return 0, errors.New("无法比较 frpc 版本")
	}
	for i := 1; i <= 3; i++ {
		a, e1 := strconv.ParseUint(left[i], 10, 32)
		b, e2 := strconv.ParseUint(right[i], 10, 32)
		if e1 != nil || e2 != nil {
			return 0, errors.New("frpc 版本号无效")
		}
		if a < b {
			return -1, nil
		}
		if a > b {
			return 1, nil
		}
	}
	if left[4] != "" && right[4] == "" {
		return -1, nil
	}
	if left[4] == "" && right[4] != "" {
		return 1, nil
	}
	if left[4] != right[4] {
		return 0, errors.New("无法比较预发布版本")
	}
	return 0, nil
}

func (u *Updater) client() *http.Client {
	if u.Client != nil {
		return u.Client
	}
	return &http.Client{Timeout: 2 * time.Minute}
}

func (u *Updater) directClient() *http.Client {
	client := *u.client()
	if client.Timeout == 0 || client.Timeout > 12*time.Second {
		client.Timeout = 12 * time.Second
	}
	return &client
}

func (u *Updater) release(ctx context.Context) (releaseInfo, error) {
	endpoint := u.API
	if endpoint == "" {
		endpoint = releaseAPI
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return releaseInfo{}, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := u.directClient().Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return releaseInfo{}, ctx.Err()
		}
		return u.acceleratedRelease(ctx)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		if resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500 {
			return u.acceleratedRelease(ctx)
		}
		return releaseInfo{}, fmt.Errorf("查询 GitHub Release 失败 (HTTP %d)", resp.StatusCode)
	}
	var release releaseInfo
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&release); err != nil {
		return u.acceleratedRelease(ctx)
	}
	if versionPattern.FindStringSubmatch(release.Tag) == nil {
		return u.acceleratedRelease(ctx)
	}
	return release, nil
}

// ghfast 不代理 api.github.com，故通过代理的 GitHub latest 跳转获取版本，
// 再读取官方 Release 发布的校验和文件用于验证安装包。
func (u *Updater) acceleratedRelease(ctx context.Context) (releaseInfo, error) {
	prefix := u.Accelerator
	if prefix == "" {
		prefix = githubAccelerator
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, prefix+githubRelease+"latest", nil)
	if err != nil {
		return releaseInfo{}, err
	}
	resp, err := u.client().Do(req)
	if err != nil {
		return releaseInfo{}, fmt.Errorf("GitHub 直连及加速均失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return releaseInfo{}, fmt.Errorf("GitHub 加速查询失败 (HTTP %d)", resp.StatusCode)
	}
	final := resp.Request.URL.String()
	base := prefix + githubRelease + "tag/"
	if !strings.HasPrefix(final, base) {
		return releaseInfo{}, errors.New("GitHub 加速返回的 Release 地址无效")
	}
	tag := strings.TrimPrefix(final, base)
	if versionPattern.FindStringSubmatch(tag) == nil {
		return releaseInfo{}, errors.New("GitHub 加速返回的版本无效")
	}
	arch := releaseArch()
	if arch == "" {
		return releaseInfo{}, errors.New("当前 CPU 架构不支持 frpc 更新")
	}
	name := fmt.Sprintf("frp_%s_linux_%s.tar.gz", strings.TrimPrefix(tag, "v"), arch)
	baseURL := githubRelease + "download/" + tag + "/"
	checksumsURL := prefix + baseURL + "frp_sha256_checksums.txt"
	checksumsReq, err := http.NewRequestWithContext(ctx, http.MethodGet, checksumsURL, nil)
	if err != nil {
		return releaseInfo{}, err
	}
	checksums, err := u.client().Do(checksumsReq)
	if err != nil {
		return releaseInfo{}, fmt.Errorf("获取 Release 校验和失败: %w", err)
	}
	defer checksums.Body.Close()
	if checksums.StatusCode != http.StatusOK {
		return releaseInfo{}, fmt.Errorf("获取 Release 校验和失败 (HTTP %d)", checksums.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(checksums.Body, 1<<20))
	if err != nil {
		return releaseInfo{}, err
	}
	for _, line := range strings.Split(string(body), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[1] == name {
			if len(fields[0]) != 64 {
				break
			}
			if _, err := hex.DecodeString(fields[0]); err != nil {
				break
			}
			return releaseInfo{Tag: tag, Assets: []releaseAsset{{Name: name, URL: baseURL + name, Digest: "sha256:" + fields[0]}}}, nil
		}
	}
	return releaseInfo{}, errors.New("Release 校验和文件缺少当前架构的有效 SHA256")
}

func (u *Updater) current(ctx context.Context) (string, error) {
	value, err := u.Runner.Run(ctx, u.Bin, "--version")
	if err != nil {
		return "", fmt.Errorf("读取当前 frpc 版本失败: %w", err)
	}
	version := strings.TrimSpace(value)
	if versionPattern.FindStringSubmatch(version) == nil {
		return "", fmt.Errorf("当前 frpc 版本号无效: %q", version)
	}
	return version, nil
}

func (u *Updater) Check(ctx context.Context) (UpdateInfo, error) {
	current, err := u.current(ctx)
	if err != nil {
		return UpdateInfo{}, err
	}
	release, err := u.release(ctx)
	if err != nil {
		return UpdateInfo{}, err
	}
	order, err := compareVersions(current, release.Tag)
	if err != nil {
		return UpdateInfo{}, err
	}
	return UpdateInfo{Current: current, Latest: release.Tag, Available: order < 0}, nil
}

func releaseArch() string {
	switch runtime.GOARCH {
	case "amd64", "arm64", "arm", "386":
		return runtime.GOARCH
	default:
		return ""
	}
}

func (u *Updater) download(ctx context.Context, release releaseInfo) (string, error) {
	arch := releaseArch()
	if arch == "" {
		return "", errors.New("当前 CPU 架构不支持 frpc 更新")
	}
	name := fmt.Sprintf("frp_%s_linux_%s.tar.gz", strings.TrimPrefix(release.Tag, "v"), arch)
	var asset releaseAsset
	for _, item := range release.Assets {
		if item.Name == name {
			asset = item
			break
		}
	}
	if asset.URL == "" {
		return "", fmt.Errorf("Release 缺少安装包 %s", name)
	}
	// 生产环境只允许固定 GitHub 项目下的 Release 资产，不能让上游 JSON 注入下载地址。
	if u.API == "" && asset.URL != githubRelease+"download/"+release.Tag+"/"+name {
		return "", errors.New("Release 下载地址不可信")
	}
	if !strings.HasPrefix(asset.Digest, "sha256:") || len(asset.Digest) != len("sha256:")+64 {
		return "", errors.New("Release 缺少 SHA256 摘要，拒绝安装")
	}
	want, err := hex.DecodeString(strings.TrimPrefix(asset.Digest, "sha256:"))
	if err != nil {
		return "", errors.New("Release SHA256 摘要无效")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, asset.URL, nil)
	if err != nil {
		return "", err
	}
	archive, err := os.CreateTemp("", "frpc-release-*.tar.gz")
	if err != nil {
		return "", err
	}
	defer os.Remove(archive.Name())
	defer archive.Close()
	resp, directErr := u.directClient().Do(req)
	if directErr == nil && resp.StatusCode == http.StatusOK {
		directErr = copyRelease(archive, resp.Body, want)
	}
	if resp != nil {
		_ = resp.Body.Close()
	}
	if directErr != nil || (resp != nil && resp.StatusCode != http.StatusOK) {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		prefix := u.Accelerator
		if prefix == "" {
			prefix = githubAccelerator
		}
		fallback, requestErr := http.NewRequestWithContext(ctx, http.MethodGet, prefix+asset.URL, nil)
		if requestErr != nil {
			return "", requestErr
		}
		resp, err = u.client().Do(fallback)
		if err != nil {
			return "", fmt.Errorf("GitHub 直连及加速下载均失败: %w", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return "", fmt.Errorf("GitHub 加速下载失败 (HTTP %d)", resp.StatusCode)
		}
		if err := archive.Truncate(0); err != nil {
			return "", err
		}
		if _, err := archive.Seek(0, io.SeekStart); err != nil {
			return "", err
		}
		if err := copyRelease(archive, resp.Body, want); err != nil {
			return "", err
		}
	}
	if _, err := archive.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	gz, err := gzip.NewReader(archive)
	if err != nil {
		return "", err
	}
	defer gz.Close()
	reader := tar.NewReader(gz)
	expected := fmt.Sprintf("frp_%s_linux_%s/frpc", strings.TrimPrefix(release.Tag, "v"), arch)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return "", err
		}
		if header.Name != expected {
			continue
		}
		if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA {
			return "", errors.New("安装包中 frpc 不是普通文件")
		}
		if header.Size <= 0 || header.Size > maxReleaseSize {
			return "", errors.New("frpc 二进制大小无效")
		}
		file, err := os.CreateTemp(filepath.Dir(u.Bin), ".frpc-update-*")
		if err != nil {
			return "", err
		}
		path := file.Name()
		if n, copyErr := io.Copy(file, io.LimitReader(reader, header.Size)); copyErr != nil || n != header.Size {
			_ = file.Close()
			_ = os.Remove(path)
			return "", errors.New("提取 frpc 二进制失败")
		}
		if err := file.Chmod(0o755); err != nil {
			_ = file.Close()
			_ = os.Remove(path)
			return "", err
		}
		if err := file.Close(); err != nil {
			_ = os.Remove(path)
			return "", err
		}
		return path, nil
	}
	return "", errors.New("安装包中未找到 frpc 二进制")
}

func copyRelease(archive *os.File, body io.Reader, want []byte) error {
	hash := sha256.New()
	count, err := io.Copy(io.MultiWriter(archive, hash), io.LimitReader(body, maxReleaseSize+1))
	if err != nil || count > maxReleaseSize {
		return errors.New("下载失败或安装包超过 100 MiB")
	}
	if !equalDigest(hash.Sum(nil), want) {
		return errors.New("frpc 安装包 SHA256 校验失败")
	}
	return nil
}

func equalDigest(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}

var ErrUpdateConflict = errors.New("frpc 版本已变化，请刷新页面后重试")
var ErrUpdateBusy = errors.New("已有 frpc 更新正在进行")

func (u *Updater) Update(ctx context.Context, expected string) (UpdateInfo, error) {
	if !u.mu.TryLock() {
		return UpdateInfo{}, ErrUpdateBusy
	}
	defer u.mu.Unlock()
	if versionPattern.FindStringSubmatch(expected) == nil {
		return UpdateInfo{}, ErrUpdateConflict
	}
	info, err := u.Check(ctx)
	if err != nil {
		return UpdateInfo{}, err
	}
	if !info.Available || info.Latest != expected {
		return UpdateInfo{}, ErrUpdateConflict
	}
	stat, err := os.Lstat(u.Bin)
	if err != nil {
		return UpdateInfo{}, err
	}
	if !stat.Mode().IsRegular() {
		return UpdateInfo{}, errors.New("frpc 路径不是普通文件，拒绝更新")
	}
	release, err := u.release(ctx)
	if err != nil {
		return UpdateInfo{}, err
	}
	if release.Tag != expected {
		return UpdateInfo{}, ErrUpdateConflict
	}
	candidate, err := u.download(ctx, release)
	if err != nil {
		return UpdateInfo{}, err
	}
	defer os.Remove(candidate)
	version, err := u.Runner.Run(ctx, candidate, "--version")
	if err != nil || strings.TrimSpace(version) != strings.TrimPrefix(expected, "v") {
		return UpdateInfo{}, errors.New("下载的 frpc 版本与目标版本不符")
	}
	// 与配置保存互斥，避免验证后磁盘配置被并发修改。
	if u.Config != nil {
		u.Config.mu.Lock()
		defer u.Config.mu.Unlock()
	}
	config, err := readSnapshot(u.ConfigPath)
	if err != nil {
		return UpdateInfo{}, err
	}
	if config.Exists {
		if err := (FRPCVerifier{Runner: u.Runner, Bin: candidate}).Verify(ctx, config.Content); err != nil {
			return UpdateInfo{}, fmt.Errorf("新版本无法校验当前配置，未更新: %w", err)
		}
	}
	// 替换二进制后即使浏览器断开，也要尽力完成启动或回滚。
	criticalCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	state := u.Service.State(criticalCtx)
	backup, err := os.CreateTemp(filepath.Dir(u.Bin), ".frpc-backup-*")
	if err != nil {
		return UpdateInfo{}, err
	}
	backupPath := backup.Name()
	keepBackup := false
	defer func() {
		if !keepBackup {
			_ = os.Remove(backupPath)
		}
	}()
	original, err := os.Open(u.Bin)
	if err != nil {
		_ = backup.Close()
		return UpdateInfo{}, err
	}
	_, err = io.Copy(backup, original)
	_ = original.Close()
	if err == nil {
		err = backup.Chmod(stat.Mode().Perm())
	}
	if err == nil {
		err = backup.Sync()
	}
	closeErr := backup.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return UpdateInfo{}, fmt.Errorf("备份旧版 frpc 失败: %w", err)
	}
	if state.Active {
		if err := u.Service.Action(criticalCtx, "stop"); err != nil {
			return UpdateInfo{}, err
		}
	}
	// 版本可能在下载期间被其他管理程序更改，不覆盖外部的更新。
	currentVersion, err := u.current(criticalCtx)
	if err != nil || currentVersion != info.Current {
		if state.Active {
			_ = u.Service.RestoreRunning(criticalCtx, true)
		}
		return UpdateInfo{}, ErrUpdateConflict
	}
	if err := os.Rename(candidate, u.Bin); err != nil {
		if state.Active {
			_ = u.Service.RestoreRunning(criticalCtx, true)
		}
		return UpdateInfo{}, fmt.Errorf("替换 frpc 失败: %w", err)
	}
	if state.Active {
		if err := u.Service.RestoreRunning(criticalCtx, true); err != nil {
			rollbackErr := os.Rename(backupPath, u.Bin)
			if rollbackErr != nil {
				keepBackup = true
			}
			restoreErr := u.Service.RestoreRunning(criticalCtx, true)
			return UpdateInfo{}, fmt.Errorf("新版本启动失败: %v；回滚二进制: %v；恢复服务: %v", err, rollbackErr, restoreErr)
		}
	}
	return UpdateInfo{Current: strings.TrimSpace(version), Latest: expected, Available: false}, nil
}
