//go:build !windows

package config

import (
	"errors"
	"os"
	"path/filepath"
)

// writeSecret (Linux and the rest): a file of mode 0600 in a folder of mode 0700, owned by the account serve runs as.
func writeSecret(dir, name, value string) (string, error) {
	p := filepath.Join(dir, name+".dsn")
	tmp, err := os.CreateTemp(dir, "."+name+".*")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return "", err
	}
	if _, err := tmp.WriteString(value); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(tmp.Name(), p); err != nil {
		return "", err
	}
	return "file:" + p, nil
}

// ResolveDPAPI reads a dpapi: reference; outside Windows there is none.
func ResolveDPAPI(string) (string, error) {
	return "", errors.New("a dpapi: reference is read on Windows only")
}
