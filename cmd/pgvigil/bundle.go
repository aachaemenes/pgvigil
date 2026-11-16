package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// keyList is a repeatable -key flag.
type keyList []string

func (k *keyList) String() string     { return fmt.Sprint(*k) }
func (k *keyList) Set(v string) error { *k = append(*k, v); return nil }

// runBundle is `pgvigil bundle inspect [-key ed25519:...] <folder>`: one bundle of a remote collector as plain JSON
// - whether it passes the checks a hub makes, its signature's result, the manifest and every line - so a site's
// security team can read what leaves before it leaves. It exits non-zero when a check or the signature fails.
func runBundle(_ context.Context, _ *slog.Logger, args []string) error {
	if len(args) == 0 || args[0] != "inspect" {
		return errors.New("usage: pgvigil bundle inspect [-key ed25519:<base64>]... [-max-mb N] <bundle folder>")
	}
	fl := flag.NewFlagSet("pgvigil bundle inspect", flag.ContinueOnError)
	fl.SetOutput(os.Stderr)
	var keys keyList
	fl.Var(&keys, "key", "a collector's public key (ed25519:<base64>, as 'pgvigil remote init' prints it); the signature is checked with it")
	maxMB := fl.Int64("max-mb", 512, "the most a view file may uncompress to")
	if err := fl.Parse(args[1:]); err != nil {
		return err
	}
	if fl.NArg() != 1 {
		return errors.New("usage: pgvigil bundle inspect [-key ed25519:<base64>]... [-max-mb N] <bundle folder>")
	}
	return inspectBundle(os.Stdout, fl.Arg(0), keys, *maxMB<<20)
}

// inspectBundle writes the bundle's report to w and returns an error when the bundle fails a check or its signature.
func inspectBundle(w io.Writer, dir string, keys []string, maxRaw int64) error {
	fsys := os.DirFS(dir)
	man, err := fs.ReadFile(fsys, format.ManifestFile)
	if err != nil {
		return report(w, dir, "no manifest.json: "+err.Error(), "", nil, nil, fsys, maxRaw)
	}
	m, err := format.DecodeManifest(man)
	if err != nil {
		return report(w, dir, err.Error(), "", nil, nil, fsys, maxRaw)
	}
	checks := "ok"
	if err := format.Verify(fsys, m, maxRaw); err != nil {
		checks = err.Error()
	}
	sig := "not signed"
	sigBytes, sigErr := fs.ReadFile(fsys, format.SigFile)
	switch {
	case len(keys) > 0 && sigErr != nil:
		sig = "refused: no manifest.sig, and a key was given"
	case len(keys) > 0:
		var pub [][]byte
		for _, k := range keys {
			b, err := config.Ed25519Key(k)
			if err != nil {
				return err
			}
			pub = append(pub, b)
		}
		sig = "ok"
		if err := format.VerifySignature(pub, man, sigBytes); err != nil {
			sig = "refused: " + err.Error()
		}
	case sigErr == nil:
		sig = "signed, not checked (no -key given)"
	}
	return report(w, dir, checks, sig, m, man, fsys, maxRaw)
}

func report(w io.Writer, dir, checks, sig string, m *format.Manifest, man []byte, fsys fs.FS, maxRaw int64) error {
	head, _ := json.MarshalIndent(map[string]string{"bundle": dir, "checks": checks, "signature": sig}, "", "  ")
	fmt.Fprintf(w, "%s\n", head)
	if m == nil {
		return fmt.Errorf("bundle %s: %s", dir, checks)
	}
	fmt.Fprintf(w, "%s", man)
	if checks == "ok" {
		for _, f := range m.Files {
			lines, err := format.ReadLines(fsys, f, maxRaw)
			if err != nil {
				return err
			}
			for _, l := range lines {
				b, _ := json.Marshal(struct {
					View string `json:"view"`
					format.Line
				}{f.View, l})
				fmt.Fprintf(w, "%s\n", b)
			}
		}
	}
	if checks != "ok" {
		return fmt.Errorf("bundle %s: %s", dir, checks)
	}
	if sig != "ok" && sig != "not signed" && sig != "signed, not checked (no -key given)" {
		return fmt.Errorf("bundle %s: signature %s", dir, sig)
	}
	return nil
}
