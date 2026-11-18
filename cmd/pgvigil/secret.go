package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"golang.org/x/term"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// 'pgvigil secret seal -name <instance> [-config pgvigil.yaml]' (L9): takes an instance's connection string on stdin
// (never a flag: a command line is read by every local account and kept in shell history; typed at a terminal it is
// not shown) and writes it to secrets/ beside the configuration - a DPAPI blob at machine scope on Windows, a file of
// mode 0600 elsewhere, readable by the service account as the configuration's own folder is - then prints the line
// for pgvigil.yaml, 'dsn: dpapi:<path>' or 'dsn: file:<path>'. The inline form keeps loading, with a warning.
func runSecret(args []string) error {
	if len(args) < 1 || args[0] != "seal" {
		return errors.New("secret: seal is the only action - pgvigil secret seal -name <instance> [-config pgvigil.yaml] < the connection string")
	}
	fs := flag.NewFlagSet("pgvigil secret seal", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file (the secret is written to secrets/ beside it)")
	name := fs.String("name", "", "the instance the connection string is for (it names the file)")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("secret seal takes flags only, got %q: the connection string comes on stdin, never as an argument", fs.Arg(0))
	}
	var in io.Reader = os.Stdin
	if fd := int(os.Stdin.Fd()); term.IsTerminal(fd) {
		fmt.Fprint(os.Stderr, "the connection string for "+*name+" (not shown), then Enter: ")
		b, err := term.ReadPassword(fd)
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return err
		}
		in = bytes.NewReader(b)
	}
	if err := secretSeal(*path, *name, in, os.Stdout); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "put that line under the instance %s in %s, in place of its dsn\n", *name, *path)
	return nil
}

// secretSeal reads the value from in, seals it for the named instance beside the configuration and writes the
// reference line to out; the value itself is never written to out.
func secretSeal(configPath, name string, in io.Reader, out io.Writer) error {
	if name == "" {
		return errors.New("secret seal: -name <instance> is required")
	}
	b, err := io.ReadAll(io.LimitReader(in, 64<<10))
	if err != nil {
		return fmt.Errorf("secret seal: reading stdin: %w", err)
	}
	value := strings.TrimRight(string(b), "\r\n")
	if strings.TrimSpace(value) == "" {
		return errors.New("secret seal: nothing on stdin - pipe the connection string in, or type it at the prompt")
	}
	ref, err := config.SealFileSecret(config.FileSecretDir(configPath), name, value)
	if err != nil {
		return fmt.Errorf("secret seal: %w", err)
	}
	_, err = fmt.Fprintf(out, "dsn: %s\n", ref)
	return err
}
