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
// not shown) and writes it to secrets/ beside the configuration - a DPAPI blob at machine scope on Windows, a file
// elsewhere - with its access set for the installed service (config.SealFileSecret), then prints the line for
// pgvigil.yaml, 'dsn: dpapi:<path>' or 'dsn: file:<path>'. The configuration must load and -name be one of its
// PostgreSQL instances, judged before the secret is asked for (rn-l9 B1). The inline form keeps loading, with a
// warning.
func runSecret(args []string) error {
	if len(args) < 1 || args[0] != "seal" {
		return errors.New("secret: seal is the only action - pgvigil secret seal -name <instance> [-config pgvigil.yaml] < the connection string")
	}
	fs := flag.NewFlagSet("pgvigil secret seal", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file (the secret is written to secrets/ beside it)")
	name := fs.String("name", "", "the PostgreSQL instance of the file the connection string is for")
	if err := fs.Parse(args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) { // rn-l9 N4: -h is no failure
			return nil
		}
		return err
	}
	if fs.NArg() > 0 { // rn-l9 S4: the count, never the text (it may be the secret)
		return fmt.Errorf("secret seal takes flags only, got %d argument(s): the connection string comes on stdin, never as an argument", fs.NArg())
	}
	if err := sealTarget(*path, *name); err != nil {
		return err
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
	ref, err := sealOnce(*path, *name, in, os.Stdout)
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "put that line under the instance %s in %s, in place of its dsn\n", *name, *path)
	if old := config.SealedFiles(*path, *name, ref); len(old) > 0 { // rn-l9 N8
		fmt.Fprintf(os.Stderr, "older seals of %s, each with the password it held: %s - delete them once pgvigil.yaml names the line above\n", *name, strings.Join(old, ", "))
	}
	return nil
}

// sealTarget (rn-l9 B1): the configuration loads, and -name is one of its PostgreSQL instances - judged before the
// secret is asked for (N4), and never echoing what -name holds (S4: it may be a connection string).
func sealTarget(configPath, name string) error {
	if name == "" {
		return errors.New("secret seal: -name <instance> is required")
	}
	cfg, err := loadConfigAt(configPath, false)
	if err != nil {
		return fmt.Errorf("secret seal: the configuration %s does not load - the secret is written beside the service's own configuration file (-config <path>): %w", configPath, err)
	}
	var pg []string
	for _, in := range cfg.Instances {
		if engineName(in) != config.EnginePostgres {
			continue
		}
		if in.Name == name {
			return nil
		}
		pg = append(pg, in.Name)
	}
	return fmt.Errorf("secret seal: -name names no PostgreSQL instance of %s (its PostgreSQL instances: %s)", configPath, strings.Join(pg, ", "))
}

// secretSeal reads the value from in, seals it for the named instance beside the configuration and writes the
// reference line to out; the value itself is never written to out.
func secretSeal(configPath, name string, in io.Reader, out io.Writer) error {
	_, err := sealOnce(configPath, name, in, out)
	return err
}

// sealServiceAccount is the installed service's account the seal is made readable for ("" = none installed); a
// variable so a test seals for no service whatever the test host has installed.
var sealServiceAccount = serviceAccountForSecrets

// sealLimit: the longest input taken (64 KiB; a connection string is never that long)
const sealLimit = 64 << 10

// sealOnce is secretSeal, answering the reference.
func sealOnce(configPath, name string, in io.Reader, out io.Writer) (string, error) {
	if err := sealTarget(configPath, name); err != nil {
		return "", err
	}
	b, err := io.ReadAll(io.LimitReader(in, sealLimit+1))
	if err != nil {
		return "", fmt.Errorf("secret seal: reading stdin: %w", err)
	}
	if len(b) > sealLimit { // rn-l9 N4: refused, never cut short
		return "", errors.New("secret seal: the input is over 64 KiB - no connection string is that long; nothing was sealed")
	}
	// a byte-order mark from a PowerShell pipe is no part of the string (rn-l9 N4)
	value := strings.TrimPrefix(strings.TrimRight(string(b), "\r\n"), "\ufeff")
	if strings.TrimSpace(value) == "" {
		return "", errors.New("secret seal: nothing on stdin - pipe the connection string in, or type it at the prompt")
	}
	ref, err := config.SealFileSecret(configPath, name, value, sealServiceAccount())
	if err != nil {
		return "", fmt.Errorf("secret seal: %w", err)
	}
	_, err = fmt.Fprintf(out, "dsn: %s\n", ref)
	return ref, err
}
