//go:build !linux && !windows

package main

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
)

func defaultInstallOptions() installOptions {
	return installOptions{Bin: "/usr/local/bin/pgvigil", Config: "/usr/local/etc/pgvigil/pgvigil.yaml", User: "pgvigil"}
}

// installService on a system without a wired service manager (macOS, the BSDs): the binary and the
// config template only; the collector runs under launchd or the init of the house.
func installService(log *slog.Logger, o installOptions) error {
	if err := installBinary(log, o.Bin); err != nil {
		return err
	}
	wrote, err := writeIfAbsent(o.Config, configTemplate("env:PGVIGIL_REPO_DSN"), 0o640)
	if err != nil {
		return err
	}
	if wrote {
		log.Info("written", "path", o.Config)
	} else {
		log.Info("kept", "path", o.Config)
	}
	fmt.Printf("no service manager is wired on this system: edit %s, set PGVIGIL_REPO_DSN and run\n  %s run -config %s\nunder launchd or your init.\n", o.Config, o.Bin, o.Config)
	return nil
}

func uninstallService(log *slog.Logger, o installOptions) error {
	if !o.Purge {
		fmt.Printf("nothing registered on this system; %s and %s are kept (pgvigil uninstall -purge removes them).\n", filepath.Dir(o.Config), o.Bin)
		return nil
	}
	if err := os.RemoveAll(filepath.Dir(o.Config)); err != nil {
		return err
	}
	if err := os.Remove(o.Bin); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	log.Info("removed", "config", filepath.Dir(o.Config), "binary", o.Bin)
	return nil
}

func maybeRunAsService(_ []string) (bool, int) { return false, 0 }

func replaceFile(tmp, dst string) error { return os.Rename(tmp, dst) }
