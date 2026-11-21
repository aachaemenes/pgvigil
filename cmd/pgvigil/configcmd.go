package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"golang.org/x/term"
)

// runConfig is 'pgvigil config export | import' (RELNOTES L155): a configuration and its secrets moved to a new server.
// Nothing secret is written to stdout, stderr or a log: an export goes to -out only, and the notes name paths and keys.
func runConfig(args []string) error {
	if len(args) == 0 {
		return &usageError{errors.New("config takes export or import: 'pgvigil config export -h', 'pgvigil config import -h'")}
	}
	switch args[0] {
	case "export":
		return runConfigExport(args[1:])
	case "import":
		return runConfigImport(args[1:])
	}
	return &usageError{fmt.Errorf("config %s: export or import", args[0])}
}

// exportPasswordMin: the shortest password an export is sealed under - the file holds the repository's login and
// every monitored server's credential, and a guess costs one scrypt derivation (about a tenth of a second a core)
const exportPasswordMin = 12

// checkExportPassword refuses an export password under exportPasswordMin characters, saying why.
func checkExportPassword(pw string) error {
	if n := len([]rune(pw)); n < exportPasswordMin {
		return fmt.Errorf("the export's password is %d characters: it seals every credential of this host, so it takes at least %d (a passphrase of a few words does); nothing written", n, exportPasswordMin)
	}
	return nil
}

// readExportPassword reads the export's password: at a terminal not shown (and asked twice for an export), from a
// pipe its one line.
func readExportPassword(twice bool) (string, error) {
	fd := int(os.Stdin.Fd())
	if !term.IsTerminal(fd) {
		return readServicePassword(os.Stdin)
	}
	ask := func(prompt string) (string, error) {
		fmt.Fprint(os.Stderr, prompt)
		b, err := term.ReadPassword(fd)
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return "", fmt.Errorf("-password-stdin: %w", err)
		}
		if strings.TrimSpace(string(b)) == "" {
			return "", errors.New("no password was typed: nothing written")
		}
		return readServicePassword(strings.NewReader(string(b)))
	}
	pw, err := ask("the export's password (not shown): ")
	if err != nil || !twice {
		return pw, err
	}
	again, err := ask("the same password again: ")
	if err != nil {
		return "", err
	}
	if again != pw {
		return "", errors.New("the two passwords differ: nothing written")
	}
	return pw, nil
}

func runConfigExport(args []string) error {
	fs := flag.NewFlagSet("pgvigil config export", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "the configuration file to export")
	noSecrets := fs.Bool("no-secrets", false, "pgvigil.yaml alone, every inline secret masked, references kept, each dpapi: reference marked not portable")
	pwStdin := fs.Bool("password-stdin", false, "pgvigil.yaml, the installer's dsn files and secrets/, instances/, sources/, every secret opened on this host, sealed under the password read from stdin (scrypt + AES-256-GCM)")
	out := fs.String("out", "", "the file to write (required: an export is never written to stdout)")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return &usageError{err}
	}
	switch {
	case *noSecrets == *pwStdin:
		return &usageError{errors.New("config export takes one of -no-secrets and -password-stdin")}
	case *out == "":
		return &usageError{errors.New("config export needs -out <file>: an export is never written to stdout")}
	case fs.NArg() > 0:
		return &usageError{fmt.Errorf("config export takes flags only, got %q", fs.Arg(0))}
	}
	if _, err := os.Stat(*out); err == nil {
		return fmt.Errorf("%s exists: name a new file for the export", *out)
	}
	var data []byte
	var said []string
	if *noSecrets {
		raw, err := os.ReadFile(*path)
		if err != nil {
			return err
		}
		if data, said, err = exportNoSecrets(raw); err != nil {
			return err
		}
	} else {
		pw, err := readExportPassword(true)
		if err != nil {
			return err
		}
		if err := checkExportPassword(pw); err != nil {
			return err
		}
		dir, err := filepath.Abs(filepath.Dir(*path))
		if err != nil {
			return err
		}
		pl, err := collectExport(*path, exportOpen(dir))
		if err != nil {
			return err
		}
		left, err := exportLeftBehind(*path)
		if err != nil {
			return err
		}
		said = append(said, left...)
		plain, err := json.Marshal(pl)
		if err != nil {
			return err
		}
		if data, err = sealExport(plain, pw); err != nil {
			return err
		}
		n := 0
		for _, f := range pl.Files {
			if f.DPAPI {
				n++
			}
		}
		said = append(said, fmt.Sprintf("%d file(s) of %s, %d of them DPAPI secrets opened on this host for the move", len(pl.Files), dir, n))
	}
	if err := os.WriteFile(*out, data, 0o600); err != nil {
		return err
	}
	for _, s := range said {
		fmt.Fprintln(os.Stderr, s)
	}
	fmt.Printf("the export is %s: keep it as you keep a password; 'pgvigil config import' on the new host reads it\n", *out)
	return nil
}

func runConfigImport(args []string) error {
	fs := flag.NewFlagSet("pgvigil config import", flag.ContinueOnError)
	path := fs.String("config", "", "the configuration file to write, named whole (required; its folder made by 'pgvigil install': /etc/pgvigil/pgvigil.yaml, %ProgramData%\\pgvigil\\pgvigil.yaml)")
	pwStdin := fs.Bool("password-stdin", false, "the export's password, read from stdin (required)")
	force := fs.Bool("force", false, "import over the configuration there; each file written over is kept as <file>.previous")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return &usageError{err}
	}
	if !*pwStdin || fs.NArg() != 1 || strings.TrimSpace(*path) == "" {
		return &usageError{errors.New("config import takes -config (the installed configuration, named whole: never the current folder), -password-stdin and the export's file: pgvigil config import -config <file> -password-stdin [-force] <file>")}
	}
	data, err := os.ReadFile(fs.Arg(0))
	if err != nil {
		return err
	}
	pw, err := readExportPassword(false)
	if err != nil {
		return err
	}
	plain, err := openExport(data, pw)
	if err != nil {
		return err
	}
	var pl exportPayload
	if err := json.Unmarshal(plain, &pl); err != nil {
		return fmt.Errorf("the export opened but its content is not read by this build: %v", err)
	}
	// the page's credential folders go to the installed service's account, as 'instance add' writes them
	notes, err := importExport(pl, *path, *force, importWriteAs(serviceAccountForSecrets()), runtime.GOOS == "windows")
	if err != nil {
		return err
	}
	for _, s := range notes {
		fmt.Fprintln(os.Stderr, s)
	}
	fmt.Printf("%d file(s) imported into %s\n", len(pl.Files), filepath.Dir(*path))
	return nil
}
