//go:build !windows

package main

// The Windows certificate store as serve's TLS (task B24n) exists on Windows only: elsewhere its flags are refused
// with one sentence (certstore_windows.go is the store; certstore_select.go its rules).

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"log/slog"
)

var errStoreWindowsOnly = errors.New("the Windows certificate store is read on Windows only: use -tls-cert and -tls-key")

func storeServerTLS(context.Context, *slog.Logger, string, string, string) (func(*tls.ClientHelloInfo) (*tls.Certificate, error), error) {
	return nil, errStoreWindowsOnly
}

func grantKeyAccess(string, string, string, io.Writer, io.Writer) error { return errStoreWindowsOnly }
