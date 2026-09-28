package main

import "testing"

func TestIsLoopbackListen(t *testing.T) {
	tests := []struct {
		address string
		want    bool
	}{
		{address: "127.0.0.1:7410", want: true},
		{address: "localhost:7410", want: true},
		{address: "[::1]:7410", want: true},
		{address: "0.0.0.0:7410", want: false},
		{address: ":7410", want: false},
		{address: "[::]:7410", want: false},
	}

	for _, test := range tests {
		t.Run(test.address, func(t *testing.T) {
			if got := isLoopbackListen(test.address); got != test.want {
				t.Fatalf("isLoopbackListen(%q) = %v, want %v", test.address, got, test.want)
			}
		})
	}
}

func TestRejectsMissingAuthentication(t *testing.T) {
	if !rejectsMissingAuthentication("0.0.0.0:7410", "", false) {
		t.Fatal("非本机监听且没有认证时应拒绝启动")
	}
	if rejectsMissingAuthentication("0.0.0.0:7410", "", true) {
		t.Fatal("显式允许免登录时不应拒绝启动")
	}
	if rejectsMissingAuthentication("0.0.0.0:7410", "token", false) {
		t.Fatal("配置认证令牌后不应拒绝启动")
	}
	if rejectsMissingAuthentication("127.0.0.1:7410", "", false) {
		t.Fatal("loopback 监听允许无令牌启动")
	}
}
