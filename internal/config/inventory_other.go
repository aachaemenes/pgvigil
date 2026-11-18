//go:build !windows

package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// prepareDir (Linux and the rest): the folder is 0700 even when it existed before with another mode.
func prepareDir(dir string) error { return os.Chmod(dir, 0o700) }

// writeSecret (Linux and the rest): a file of mode 0600 (from its creation) in a folder of mode 0700, owned by the
// account serve runs as.
func writeSecret(dir, name, value string) (string, error) {
	p := filepath.Join(dir, name+".dsn")
	tmp, err := os.CreateTemp(dir, "."+name+".*")
	if err != nil {
		return "", err
	}
	defer func() { _ = os.Remove(tmp.Name()) }() // gone after the rename; this removes it on a failure
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return "", err
	}
	if _, err := tmp.WriteString(value); err != nil {
		_ = tmp.Close()
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

// ownedLikeParent gives path the owner of its parent folder when they differ (SealFileSecret: the configuration's
// folder is the service account's, made so by the installer), and a folder the mode 0700. A run that is neither root
// nor that owner cannot change the owner, and the error says so.
func ownedLikeParent(path string) error {
	st, err := os.Stat(path)
	if err != nil {
		return err
	}
	pst, err := os.Stat(filepath.Dir(path))
	if err != nil {
		return err
	}
	if st.IsDir() {
		if err := os.Chmod(path, 0o700); err != nil {
			return err
		}
	}
	own, ok1 := st.Sys().(*syscall.Stat_t)
	par, ok2 := pst.Sys().(*syscall.Stat_t)
	if !ok1 || !ok2 || (own.Uid == par.Uid && own.Gid == par.Gid) {
		return nil
	}
	if err := os.Chown(path, int(par.Uid), int(par.Gid)); err != nil {
		return fmt.Errorf("%s could not be given the owner of %s (run this as root or as that account): %w", path, filepath.Dir(path), err)
	}
	return nil
}
