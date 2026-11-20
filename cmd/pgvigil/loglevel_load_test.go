package main

import (
	"bytes"
	"context"
	"go/ast"
	"go/parser"
	"go/token"
	stdlog "log"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// TestEveryConfigLoadAppliesTheLevel: every command that reads pgvigil.yaml reads it through loadFile, which applies
// log_level - a direct config.Load leaves the command at info whatever the file says (serve, mcp, purge, export,
// demo, tag, user, report, the installer's dsn read, 'pgvigil import'). Two side reads keep config.Load: the
// installer's reports_dsn look (runUpgrade) and the Windows purge's list of the file's items (purgeYAMLItems).
func TestEveryConfigLoadAppliesTheLevel(t *testing.T) {
	allowed := map[string]bool{"main.go loadFile": true, "install.go runUpgrade": true, "service_windows.go purgeYAMLItems": true}
	var bad []string
	for _, dir := range []string{".", filepath.Join("..", "..", "internal", "dbadash")} {
		files, err := filepath.Glob(filepath.Join(dir, "*.go"))
		if err != nil {
			t.Fatal(err)
		}
		for _, f := range files {
			if strings.HasSuffix(f, "_test.go") {
				continue
			}
			fset := token.NewFileSet()
			file, err := parser.ParseFile(fset, f, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			for _, d := range file.Decls {
				fn, ok := d.(*ast.FuncDecl)
				if !ok {
					continue
				}
				ast.Inspect(fn, func(n ast.Node) bool {
					call, ok := n.(*ast.CallExpr)
					if !ok {
						return true
					}
					sel, ok := call.Fun.(*ast.SelectorExpr)
					if !ok {
						return true
					}
					if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "config" && sel.Sel.Name == "Load" {
						where := filepath.Base(f) + " " + fn.Name.Name
						if !allowed[where] || dir != "." {
							bad = append(bad, fset.Position(call.Pos()).String()+" in "+fn.Name.Name)
						}
					}
					return true
				})
			}
		}
	}
	sort.Strings(bad)
	if len(bad) > 0 {
		t.Errorf("config.Load outside loadFile (the file's log_level not applied):\n  %s", strings.Join(bad, "\n  "))
	}
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "dbadash.LoadConfig = loadFile") {
		t.Error("main.go does not set dbadash.LoadConfig = loadFile: 'pgvigil import' reads the file without its log_level")
	}
}

// TestServeAppliesTheFileLevel: 'pgvigil serve' with log_level: debug in its file runs at debug. The file's empty
// repository dsn stops serve right after the load (a configuration error), so the level is read there.
func TestServeAppliesTheFileLevel(t *testing.T) {
	old := logLevel.Level()
	defer logLevel.Set(old)
	logLevel.Set(slog.LevelInfo)
	t.Setenv("PGVIGIL_LOG_LEVEL", "")
	p := filepath.Join(t.TempDir(), "pgvigil.yaml")
	if err := os.WriteFile(p, []byte("log_level: debug\nrepository:\n  dsn: \"\"\ninstances: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil))
	err := runServe(context.Background(), log, []string{"-config", p})
	if err == nil || !strings.Contains(err.Error(), "resolves to nothing") {
		t.Fatalf("serve with an empty repository dsn: %v, want the configuration error", err)
	}
	if got := logLevel.Level(); got != slog.LevelDebug {
		t.Errorf("serve with log_level: debug runs at %v, want DEBUG", got)
	}
}

// TestLoadFileSaysTheOverride: PGVIGIL_LOG_LEVEL set and different from the file's log_level writes one Warn line
// naming both (on a service the variable outlives restarts and upgrades); the same word, no variable, or a word that is
// no level writes none.
func TestLoadFileSaysTheOverride(t *testing.T) {
	old := logLevel.Level()
	defer logLevel.Set(old)
	defLog := slog.Default()
	defer slog.SetDefault(defLog)
	p := filepath.Join(t.TempDir(), "pgvigil.yaml")
	if err := os.WriteFile(p, []byte("log_level: warn\nrepository:\n  dsn: \"\"\ninstances: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		env   string
		lines int
		level slog.Level
	}{
		{"debug", 1, slog.LevelDebug},
		{"warn", 0, slog.LevelWarn},
		{"", 0, slog.LevelWarn},
		{"loud", 0, slog.LevelWarn},
	} {
		var buf bytes.Buffer
		slog.SetDefault(slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
		logLevel.Set(slog.LevelInfo)
		t.Setenv("PGVIGIL_LOG_LEVEL", c.env)
		if _, err := loadFile(p); err != nil {
			t.Fatalf("PGVIGIL_LOG_LEVEL=%q: %v", c.env, err)
		}
		var said []string
		for _, l := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
			if strings.Contains(l, "overrides the configuration's log_level") {
				said = append(said, l)
			}
		}
		if len(said) != c.lines {
			t.Errorf("PGVIGIL_LOG_LEVEL=%q over log_level: warn: %d override line(s) %q, want %d", c.env, len(said), said, c.lines)
		}
		if c.lines == 1 && len(said) == 1 && !(strings.Contains(said[0], "level=WARN") && strings.Contains(said[0], "PGVIGIL_LOG_LEVEL=debug") && strings.Contains(said[0], "log_level=warn")) {
			t.Errorf("the override line %q: want a WARN naming PGVIGIL_LOG_LEVEL=debug and log_level=warn", said[0])
		}
		if got := logLevel.Level(); got != c.level {
			t.Errorf("PGVIGIL_LOG_LEVEL=%q over log_level: warn: the level %v, want %v", c.env, got, c.level)
		}
	}
}

// TestWarnBadLevelWritesOneLine: an unknown PGVIGIL_LOG_LEVEL is one Warn line naming the value - the console's line
// and the Windows service's (both call warnBadLevel); none for a level word.
func TestWarnBadLevelWritesOneLine(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewTextHandler(&buf, nil))
	warnBadLevel(log, "")
	if buf.Len() != 0 {
		t.Fatalf("no bad word: %q, want nothing", buf.String())
	}
	warnBadLevel(log, "loud")
	got := strings.TrimSpace(buf.String())
	if strings.Count(got, "\n") != 0 || !strings.Contains(got, "level=WARN") || !strings.Contains(got, "value=loud") {
		t.Errorf("bad word 'loud': %q, want one WARN line with value=loud", got)
	}
}

// TestStandardLogLineAfterSetDefault: after slog.SetDefault (run and the Windows service do it with the process's
// logger), a line of the standard log package - a library's - is written through that logger's handler at INFO, so
// log_level governs it: shown at info, dropped at warn.
func TestStandardLogLineAfterSetDefault(t *testing.T) {
	old := logLevel.Level()
	defer logLevel.Set(old)
	defLog, flags, out := slog.Default(), stdlog.Flags(), stdlog.Writer()
	defer func() { slog.SetDefault(defLog); stdlog.SetFlags(flags); stdlog.SetOutput(out) }()
	var buf bytes.Buffer
	logLevel.Set(slog.LevelInfo)
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: logLevel})))
	stdlog.Print("a library line at info")
	logLevel.Set(slog.LevelWarn)
	stdlog.Print("a library line at warn")
	got := buf.String()
	if !strings.Contains(got, `level=INFO msg="a library line at info"`) {
		t.Errorf("at info the standard log line reads %q, want it at level=INFO through the handler", got)
	}
	if strings.Contains(got, "a library line at warn") {
		t.Errorf("at warn the standard log line was written: %q, want it dropped (it is an INFO line)", got)
	}
}
