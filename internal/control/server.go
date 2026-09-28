package control

import (
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"mime"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
)

const MaxRequestBody = MaxConfigSize + 64<<10

type Server struct {
	Static     fs.FS
	Config     *ConfigManager
	Service    SystemService
	FRPCBin    string
	ConfigPath string
}

type apiResponse struct {
	OK      bool   `json:"ok"`
	Data    any    `json:"data,omitempty"`
	Message string `json:"message,omitempty"`
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/api/config", s.handleConfig)
	mux.HandleFunc("/api/logs", s.handleLogs)
	mux.HandleFunc("/api/verify", s.handleVerify)
	mux.HandleFunc("/api/service", s.handleService)
	mux.HandleFunc("/api/", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusNotFound, apiResponse{OK: false, Message: "Not Found"})
	})
	mux.HandleFunc("/", s.handleStatic)
	return s.securityHeaders(mux)
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	writeJSON(w, http.StatusOK, apiResponse{OK: true, Data: s.Service.Status(r.Context(), s.FRPCBin, s.ConfigPath)})
}

func (s *Server) handleConfig(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		snapshot, err := s.Config.Read()
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, apiResponse{OK: false, Message: "读取配置失败: " + err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, apiResponse{OK: true, Data: snapshot})
	case http.MethodPost:
		if err := validateSameOrigin(r); err != nil {
			writeJSON(w, http.StatusForbidden, apiResponse{OK: false, Message: err.Error()})
			return
		}
		var request ApplyRequest
		if err := decodeJSON(w, r, &request); err != nil {
			writeRequestError(w, err)
			return
		}
		result, err := s.Config.Apply(r.Context(), request)
		if errors.Is(err, ErrRevisionConflict) || (err != nil && strings.Contains(err.Error(), "保存过程中发生变化")) {
			writeJSON(w, http.StatusConflict, apiResponse{OK: false, Message: err.Error()})
			return
		}
		if err != nil {
			status := http.StatusInternalServerError
			if strings.Contains(err.Error(), "不能为空") || strings.Contains(err.Error(), "校验失败") || strings.Contains(err.Error(), "1 MiB") {
				status = http.StatusBadRequest
			}
			writeJSON(w, status, apiResponse{OK: false, Data: result, Message: err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, apiResponse{OK: true, Data: result, Message: result.Message})
	default:
		methodNotAllowed(w)
	}
}

func (s *Server) handleLogs(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	lines := 120
	if value := r.URL.Query().Get("lines"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 1 || parsed > 1000 {
			writeJSON(w, http.StatusBadRequest, apiResponse{OK: false, Message: "lines 必须是 1 到 1000 的整数"})
			return
		}
		lines = parsed
	}
	logs, err := s.Service.Logs(r.Context(), lines)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, apiResponse{OK: false, Message: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, apiResponse{OK: true, Data: map[string]string{"logs": logs}})
}

func (s *Server) handleVerify(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	if err := validateSameOrigin(r); err != nil {
		writeJSON(w, http.StatusForbidden, apiResponse{OK: false, Message: err.Error()})
		return
	}
	var request struct {
		Content string `json:"content"`
	}
	if err := decodeJSON(w, r, &request); err != nil {
		writeRequestError(w, err)
		return
	}
	if strings.TrimSpace(request.Content) == "" {
		writeJSON(w, http.StatusBadRequest, apiResponse{OK: false, Message: "配置内容不能为空"})
		return
	}
	if len(request.Content) > MaxConfigSize {
		writeJSON(w, http.StatusBadRequest, apiResponse{OK: false, Message: "配置内容超过 1 MiB 限制"})
		return
	}
	if err := s.Config.Verifier.Verify(r.Context(), request.Content); err != nil {
		writeJSON(w, http.StatusBadRequest, apiResponse{OK: false, Message: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, apiResponse{OK: true, Message: "配置校验通过"})
}

func (s *Server) handleService(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	if err := validateSameOrigin(r); err != nil {
		writeJSON(w, http.StatusForbidden, apiResponse{OK: false, Message: err.Error()})
		return
	}
	var request struct {
		Action string `json:"action"`
	}
	if err := decodeJSON(w, r, &request); err != nil {
		writeRequestError(w, err)
		return
	}
	if request.Action != "start" && request.Action != "stop" && request.Action != "restart" {
		writeJSON(w, http.StatusBadRequest, apiResponse{OK: false, Message: "不支持的服务动作"})
		return
	}
	if request.Action != "stop" {
		snapshot, err := s.Config.Read()
		if err != nil || !snapshot.Exists {
			writeJSON(w, http.StatusBadRequest, apiResponse{OK: false, Message: "请先在网页中保存有效的 frpc 配置"})
			return
		}
		if err := s.Config.Verifier.Verify(r.Context(), snapshot.Content); err != nil {
			writeJSON(w, http.StatusBadRequest, apiResponse{OK: false, Message: err.Error()})
			return
		}
	}
	if err := s.Service.Action(r.Context(), request.Action); err != nil {
		writeJSON(w, http.StatusInternalServerError, apiResponse{OK: false, Message: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, apiResponse{OK: true, Message: "frpc 已执行 " + request.Action})
}

func (s *Server) handleStatic(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/api/") {
		writeJSON(w, http.StatusNotFound, apiResponse{OK: false, Message: "Not Found"})
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		methodNotAllowed(w)
		return
	}
	if s.Static == nil {
		http.NotFound(w, r)
		return
	}
	requested := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
	if requested == "." || requested == "" {
		requested = "index.html"
	}
	content, err := fs.ReadFile(s.Static, requested)
	if err != nil {
		content, err = fs.ReadFile(s.Static, "index.html")
		requested = "index.html"
	}
	if err != nil {
		http.NotFound(w, r)
		return
	}
	contentType := mime.TypeByExtension(path.Ext(requested))
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Length", strconv.Itoa(len(content)))
	if r.Method == http.MethodGet {
		_, _ = w.Write(content)
	}
}

func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		next.ServeHTTP(w, r)
	})
}

type requestError struct {
	Status  int
	Message string
}

func (e *requestError) Error() string { return e.Message }

func decodeJSON(w http.ResponseWriter, r *http.Request, destination any) error {
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return &requestError{Status: http.StatusUnsupportedMediaType, Message: "请求必须使用 application/json"}
	}
	if r.ContentLength > MaxRequestBody {
		return &requestError{Status: http.StatusRequestEntityTooLarge, Message: "请求体超过限制"}
	}
	r.Body = http.MaxBytesReader(w, r.Body, MaxRequestBody)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			return &requestError{Status: http.StatusRequestEntityTooLarge, Message: "请求体超过限制"}
		}
		return &requestError{Status: http.StatusBadRequest, Message: "请求体不是合法 JSON 对象"}
	}
	var trailing any
	if err := decoder.Decode(&trailing); err == nil {
		return &requestError{Status: http.StatusBadRequest, Message: "请求体只能包含一个 JSON 对象"}
	} else if !errors.Is(err, io.EOF) {
		return &requestError{Status: http.StatusBadRequest, Message: "请求体包含非法尾随内容"}
	}
	return nil
}

func validateSameOrigin(r *http.Request) error {
	if strings.EqualFold(r.Header.Get("Sec-Fetch-Site"), "cross-site") {
		return errors.New("拒绝跨站请求")
	}
	origin := r.Header.Get("Origin")
	if origin == "" {
		return nil
	}
	parsed, err := url.Parse(origin)
	if err != nil || !strings.EqualFold(parsed.Host, r.Host) {
		return errors.New("请求来源与当前控制台不一致")
	}
	return nil
}

func writeRequestError(w http.ResponseWriter, err error) {
	var typed *requestError
	if errors.As(err, &typed) {
		writeJSON(w, typed.Status, apiResponse{OK: false, Message: typed.Message})
		return
	}
	writeJSON(w, http.StatusBadRequest, apiResponse{OK: false, Message: err.Error()})
}

func writeJSON(w http.ResponseWriter, status int, response apiResponse) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(response)
}

func methodNotAllowed(w http.ResponseWriter) {
	writeJSON(w, http.StatusMethodNotAllowed, apiResponse{OK: false, Message: "Method Not Allowed"})
}
