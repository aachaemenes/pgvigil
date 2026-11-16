//go:build !linux && !windows

package main

import (
	"errors"
	"log/slog"
)

func remoteConfigDefault() string  { return "/etc/pgvigil-remote/pgvigil-remote.yaml" }
func remoteAccountDefault() string { return "pgvigil-remote" }

func installRemoteService(_ *slog.Logger, _ installOptions) error {
	return errors.New("install -remote: Linux and Windows only (run pgvigil run -config <file> under the platform's own service manager)")
}
