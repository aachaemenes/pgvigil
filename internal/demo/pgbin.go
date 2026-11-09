package demo

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Cluster is a throwaway PostgreSQL run from a portable binary folder (the EDB zip's pgsql\bin on
// Windows, a tarball's bin on Linux or macOS): no service, no admin right, no Docker. It listens on
// 127.0.0.1 only, on a free port, with a password login (scram-sha-256) whose password is kept in
// the data folder; Stop shuts it down.
type Cluster struct {
	bin, data, sock string
	Port            int
	DSN             string // the repository database 'pgvigil' as the superuser
	log             *slog.Logger
}

func exe(name string) string {
	if runtime.GOOS == "windows" {
		return name + ".exe"
	}
	return name
}

// findBin accepts the bin folder itself or the folder above it (pgsql, the tarball root).
func findBin(dir string) (string, error) {
	for _, d := range []string{dir, filepath.Join(dir, "bin"), filepath.Join(dir, "pgsql", "bin")} {
		if _, err := os.Stat(filepath.Join(d, exe("pg_ctl"))); err == nil {
			if _, err := os.Stat(filepath.Join(d, exe("initdb"))); err == nil {
				return d, nil
			}
		}
	}
	return "", fmt.Errorf("-pgbin %s: no %s and %s there (nor in its bin or pgsql\\bin folder)", dir, exe("initdb"), exe("pg_ctl"))
}

func freePort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer func() { _ = ln.Close() }()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

func (c *Cluster) run(ctx context.Context, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, filepath.Join(c.bin, exe(name)), args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %w\n%s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// start runs pg_ctl start with its output in a file, not a pipe: on Windows the postmaster pg_ctl
// spawns inherits the handles, and a captured pipe would keep the call waiting until the server exits.
func (c *Cluster) start(ctx context.Context, opts string) error {
	outPath := filepath.Join(c.data, "pgvigil-demo-pgctl.out")
	out, err := os.Create(outPath)
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, filepath.Join(c.bin, exe("pg_ctl")), "-D", c.data, "-l", filepath.Join(c.data, "pgvigil-demo.log"),
		"-o", opts, "-w", "-t", "120", "start")
	cmd.Stdout, cmd.Stderr = out, out
	runErr := cmd.Run()
	_ = out.Close()
	if runErr != nil {
		b, _ := os.ReadFile(outPath)
		l, _ := os.ReadFile(filepath.Join(c.data, "pgvigil-demo.log"))
		return fmt.Errorf("pg_ctl start: %w\n%s\n%s", runErr, strings.TrimSpace(string(b)), tail(string(l), 2000))
	}
	return nil
}

func tail(s string, n int) string {
	if len(s) > n {
		return s[len(s)-n:]
	}
	return s
}

// StartCluster initialises data (when it holds no cluster yet), starts the server on a free
// loopback port and creates the repository database. The caller must Stop it.
func StartCluster(ctx context.Context, log *slog.Logger, binDir, data string) (*Cluster, error) {
	bin, err := findBin(binDir)
	if err != nil {
		return nil, err
	}
	data, err = filepath.Abs(data)
	if err != nil {
		return nil, err
	}
	c := &Cluster{bin: bin, data: data, log: log}
	pwFile := filepath.Join(data, "pgvigil-demo.pw")
	if _, err := os.Stat(filepath.Join(data, "PG_VERSION")); errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(data, 0o700); err != nil {
			return nil, err
		}
		b := make([]byte, 18)
		if _, err := rand.Read(b); err != nil {
			return nil, err
		}
		tmp, err := os.CreateTemp("", "pgvigil-pw-*")
		if err != nil {
			return nil, err
		}
		_, werr := tmp.WriteString(hex.EncodeToString(b) + "\n")
		cerr := tmp.Close()
		defer func() { _ = os.Remove(tmp.Name()) }()
		if werr != nil || cerr != nil {
			return nil, errors.Join(werr, cerr)
		}
		log.Info("demo: initdb", "data", data)
		if err := c.run(ctx, "initdb", "-D", data, "-U", "postgres", "-A", "scram-sha-256", "--pwfile", tmp.Name(),
			"-E", "UTF8", "--no-locale"); err != nil {
			return nil, err
		}
		// the password lives in the data folder (0700, the server's own): a re-run reuses the cluster
		if err := os.WriteFile(pwFile, []byte(hex.EncodeToString(b)), 0o600); err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, err
	}
	pw, err := os.ReadFile(pwFile)
	if err != nil {
		return nil, fmt.Errorf("%s holds a cluster this command did not make (no pgvigil-demo.pw): name an empty or new -pgdata folder: %w", data, err)
	}
	// a server of this folder still up (the last run was killed, not stopped) is ours: stop it, so the
	// start below gets a fresh port instead of failing on the lock file
	if exec.CommandContext(ctx, filepath.Join(bin, exe("pg_ctl")), "-D", data, "status").Run() == nil {
		log.Warn("demo: the demo cluster of this folder was left running; stopping it first", "data", data)
		if err := c.run(ctx, "pg_ctl", "-D", data, "-m", "fast", "-w", "stop"); err != nil {
			return nil, err
		}
	}
	if c.Port, err = freePort(); err != nil {
		return nil, err
	}
	opts := fmt.Sprintf(`-p %d -c listen_addresses=127.0.0.1`, c.Port)
	if runtime.GOOS != "windows" {
		// the default socket folder (/run/postgresql, /tmp) may not be ours; a short private one is
		if c.sock, err = os.MkdirTemp("", "pgv"); err != nil {
			return nil, err
		}
		opts += ` -k "` + c.sock + `"`
	}
	log.Info("demo: starting PostgreSQL", "bin", bin, "port", c.Port)
	if err := c.start(ctx, opts); err != nil {
		c.cleanSock()
		return nil, err
	}
	admin := fmt.Sprintf("host=127.0.0.1 port=%d user=postgres password=%s dbname=postgres sslmode=disable", c.Port, strings.TrimSpace(string(pw)))
	conn, err := pgx.Connect(ctx, admin)
	if err != nil {
		c.Stop()
		return nil, fmt.Errorf("connect to the demo cluster: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	var exists bool
	if err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'pgvigil')`).Scan(&exists); err != nil {
		c.Stop()
		return nil, err
	}
	if !exists {
		if _, err := conn.Exec(ctx, `CREATE DATABASE pgvigil`); err != nil {
			c.Stop()
			return nil, err
		}
	}
	c.DSN = strings.Replace(admin, "dbname=postgres", "dbname=pgvigil", 1)
	return c, nil
}

// Stop shuts the server down (fast: open sessions are ended) and waits for it.
func (c *Cluster) Stop() {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if err := c.run(ctx, "pg_ctl", "-D", c.data, "-m", "fast", "-w", "stop"); err != nil {
		c.log.Warn("demo: stopping PostgreSQL", "err", err)
	} else {
		c.log.Info("demo: PostgreSQL stopped", "data", c.data)
	}
	c.cleanSock()
}

func (c *Cluster) cleanSock() {
	if c.sock != "" {
		_ = os.RemoveAll(c.sock)
	}
}
