//go:build !windows

package config

import (
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
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

// ownedLikeParent gives path the access its parent folder grants (SealFileSecret): the parent's owner and group, and
// its mode without the bits for others - a folder takes the parent's mode (0750 under the installer's root:<service
// group> 0750 configuration folder, so the service's group enters it), a file 0640 when the parent's group may read,
// else 0600 (the installer's own files are 0640 there). A run that is neither root nor the parent's owner cannot
// change the owner, and the error says so.
func ownedLikeParent(path string) error {
	st, err := os.Stat(path)
	if err != nil {
		return err
	}
	pst, err := os.Stat(filepath.Dir(path))
	if err != nil {
		return err
	}
	groupReads := pst.Mode().Perm()&0o040 != 0
	mode := os.FileMode(0o600)
	if st.IsDir() {
		mode = (pst.Mode().Perm() &^ 0o007) | 0o700
	} else if groupReads {
		mode = 0o640
	}
	if err := os.Chmod(path, mode); err != nil {
		return err
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

// SealDPAPIAt: a DPAPI blob is sealed on Windows only (RELNOTES L155's import refuses such an entry first).
func SealDPAPIAt(string, string) error {
	return errors.New("a dpapi: secret is sealed on Windows only")
}

// OwnLikeFolder gives path its folder's owner and the installer's mode: 0640 where the folder's group reads, else
// 0600; a folder 07x0 (ownedLikeParent).
func OwnLikeFolder(path string) error { return ownedLikeParent(path) }

// accountIDs is an account's uid and gid (the system's account list; no cgo).
func accountIDs(account string) (int, int, error) {
	u, err := user.Lookup(account)
	if err != nil {
		return 0, 0, fmt.Errorf("the account %s: %w", account, err)
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil {
		return 0, 0, err
	}
	gid, err := strconv.Atoi(u.Gid)
	if err != nil {
		return 0, 0, err
	}
	return uid, gid, nil
}

func knownAccount(account string) error { _, _, err := accountIDs(account); return err }

// prepareDirAs: the folder 0700, owned by the account (root changes the owner; the account itself needs not).
func prepareDirAs(dir, account string) error {
	uid, gid, err := accountIDs(account)
	if err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	return os.Lchown(dir, uid, gid)
}

// ownFileAs: the file the account's own, its mode kept (0600).
func ownFileAs(path, account string) error {
	uid, gid, err := accountIDs(account)
	if err != nil {
		return err
	}
	return os.Lchown(path, uid, gid)
}
