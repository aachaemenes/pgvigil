//go:build windows

package main

// task B24n's proof on a Windows machine: scripts/proof-certstore-windows.ps1 runs these tests from a cross-built test
// binary (GOOS=windows go test -c ./cmd/pgvigil) against certificates it makes in the store. Each test SKIPS unless
// the proof names a certificate in its environment, so a plain `go test` on Windows runs none of it.
//   PGVIGIL_CS_STORE    the store (default LocalMachine\My)
//   PGVIGIL_CS_THUMB    the certificate by thumbprint, or PGVIGIL_CS_SUBJECT by DNS name (TestCertstoreProofServe)
//   TestCertstoreProofSign: every signing form crypto/tls can ask of the key, each verified with the leaf's public key
//     (RSA: PKCS#1 v1.5 with SHA-1 / 256 / 384 / 512 and PSS with the hash's salt; ECDSA: SHA-1 / 256 / 384 / 512 digests)
//   TestCertstoreProofServe (PGVIGIL_CS_SERVE=1): a TLS server on 127.0.0.1 with serve's own tls.Config over
//     storeServerTLS (the GetCertificate serve uses), and a client that trusts only PGVIGIL_CS_ROOT (a DER .cer) and
//     checks the name PGVIGIL_CS_NAME (PGVIGIL_CS_ROOT may list several files, ';' between): one TLS 1.2 and one
//     TLS 1.3 handshake, the leaf served and the chain sent;
//     PGVIGIL_CS_PARALLEL=<n>: n handshakes at once (TLS 1.3 and 1.2 in turn) on the one key handle;
//     PGVIGIL_CS_RENEW=<file> (subject mode): re-selection every 10 s (the proof knob), the first leaf printed and
//     written to <file>.first, then <file> waited for (it holds the thumbprint the renewal must serve) and handshakes
//     made until that leaf is served, by the same server, with no restart.
//   TestCertstoreProofAsUser (PGVIGIL_CS_ASUSER, PGVIGIL_CS_ASPASS in the environment only, PGVIGIL_CS_THUMB,
//     PGVIGIL_CS_EXPECT refused|opens): the certificate is selected and its key opened (with the start probe's
//     signature) on a thread impersonating that local user's interactive logon - the key's access check is the
//     user's - and the outcome graded against PGVIGIL_CS_EXPECT. The proof's fallback for a door where a process
//     cannot be started as another user.
// Every result line opens "CS " for the script to grade.

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1"
	_ "crypto/sha512" // SHA-384 / SHA-512 digests
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

func csLine(t *testing.T, what string, err error) {
	t.Helper()
	if err != nil {
		fmt.Printf("CS %s FAIL %v\n", what, err)
		t.Errorf("%s: %v", what, err)
		return
	}
	fmt.Printf("CS %s ok\n", what)
}

func TestCertstoreProofSign(t *testing.T) {
	thumb := os.Getenv("PGVIGIL_CS_THUMB")
	if thumb == "" {
		t.Skip("PGVIGIL_CS_THUMB is not set: scripts/proof-certstore-windows.ps1 sets it")
	}
	location, name, err := parseStoreName(os.Getenv("PGVIGIL_CS_STORE"))
	if err != nil {
		t.Fatal(err)
	}
	sc, err := pick(location, name, thumb, "", time.Now())
	if err != nil {
		fmt.Printf("CS refused: %v\n", err)
		t.Fatal(err)
	}
	defer sc.close()
	signer, ok := sc.tls.PrivateKey.(*ncryptSigner)
	if !ok {
		t.Fatalf("the served key is a %T, not the CNG signer", sc.tls.PrivateKey)
	}
	msg := []byte("pgvigil B24n: one message signed in every form")
	digest := func(h crypto.Hash) []byte {
		w := h.New()
		_, _ = w.Write(msg)
		return w.Sum(nil)
	}
	hashes := []crypto.Hash{crypto.SHA1, crypto.SHA256, crypto.SHA384, crypto.SHA512}
	switch pub := signer.Public().(type) {
	case *rsa.PublicKey:
		for _, h := range hashes {
			d := digest(h)
			sig, err := signer.Sign(rand.Reader, d, h)
			if err == nil {
				err = rsa.VerifyPKCS1v15(pub, h, d, sig)
			}
			csLine(t, fmt.Sprintf("sign rsa-%d pkcs1v15 %v", pub.N.BitLen(), h), err)
		}
		for _, h := range hashes[1:] { // TLS asks PSS with SHA-256 / 384 / 512 only
			d := digest(h)
			opts := &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash, Hash: h}
			sig, err := signer.Sign(rand.Reader, d, opts)
			if err == nil {
				err = rsa.VerifyPSS(pub, h, d, sig, opts)
			}
			csLine(t, fmt.Sprintf("sign rsa-%d pss %v", pub.N.BitLen(), h), err)
		}
	case *ecdsa.PublicKey:
		for _, h := range hashes {
			d := digest(h)
			sig, err := signer.Sign(rand.Reader, d, h)
			if err == nil && !ecdsa.VerifyASN1(pub, d, sig) {
				err = errors.New("the DER signature does not verify")
			}
			csLine(t, fmt.Sprintf("sign ecdsa-%s %v", pub.Curve.Params().Name, h), err)
		}
	default:
		t.Fatalf("the key is a %T", pub)
	}
}

// csSeen is what one client handshake saw.
type csSeen struct {
	leaf     string // the served leaf's thumbprint
	chain    int    // certificates sent
	rootSent bool   // a self-signed certificate after the leaf
	version  string
}

func csThumb(der []byte) string {
	sum := sha1.Sum(der) // a thumbprint, not a security hash
	return strings.ToUpper(hex.EncodeToString(sum[:]))
}

func TestCertstoreProofServe(t *testing.T) {
	if os.Getenv("PGVIGIL_CS_SERVE") != "1" {
		t.Skip("PGVIGIL_CS_SERVE is not 1: scripts/proof-certstore-windows.ps1 sets it")
	}
	thumb, subject, renew := os.Getenv("PGVIGIL_CS_THUMB"), os.Getenv("PGVIGIL_CS_SUBJECT"), os.Getenv("PGVIGIL_CS_RENEW")
	if renew != "" {
		if subject == "" {
			t.Fatal("PGVIGIL_CS_RENEW needs subject mode (PGVIGIL_CS_SUBJECT)")
		}
		reselectKnob = "on" // what -ldflags "-X main.reselectKnob=on" does in a proof build
		t.Setenv("PGVIGIL_TLS_RESELECT", "10s")
	}
	roots := x509.NewCertPool()
	for _, f := range strings.Split(os.Getenv("PGVIGIL_CS_ROOT"), ";") {
		der, err := os.ReadFile(strings.TrimSpace(f))
		if err != nil {
			t.Fatalf("PGVIGIL_CS_ROOT: %v", err)
		}
		root, err := x509.ParseCertificate(der)
		if err != nil {
			t.Fatalf("PGVIGIL_CS_ROOT %s: %v", f, err)
		}
		roots.AddCert(root)
	}
	serverName := os.Getenv("PGVIGIL_CS_NAME")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	get, err := storeServerTLS(ctx, slog.New(slog.NewTextHandler(os.Stdout, nil)), os.Getenv("PGVIGIL_CS_STORE"), thumb, subject)
	if err != nil {
		fmt.Printf("CS refused: %v\n", err)
		t.Fatal(err)
	}
	// serve's own configuration (serve.go with the B24n wiring)
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{GetCertificate: get, MinVersion: tls.VersionTLS12})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer func() { _ = c.Close() }()
				_ = c.SetDeadline(time.Now().Add(30 * time.Second))
				if c.(*tls.Conn).Handshake() == nil {
					_, _ = c.Write([]byte("ok"))
				}
			}()
		}
	}()
	dial := func(version uint16) (csSeen, error) {
		d := &net.Dialer{Timeout: 30 * time.Second}
		conn, err := tls.DialWithDialer(d, "tcp", ln.Addr().String(), &tls.Config{RootCAs: roots, ServerName: serverName, MinVersion: version, MaxVersion: version})
		if err != nil {
			return csSeen{}, err
		}
		defer func() { _ = conn.Close() }()
		_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
		buf := make([]byte, 2)
		if _, err := io.ReadFull(conn, buf); err != nil || string(buf) != "ok" {
			return csSeen{}, fmt.Errorf("the server's answer after the handshake: %q %v", buf, err)
		}
		st := conn.ConnectionState()
		seen := csSeen{leaf: csThumb(st.PeerCertificates[0].Raw), chain: len(st.PeerCertificates), version: tls.VersionName(st.Version)}
		for _, c := range st.PeerCertificates[1:] {
			if c.CheckSignatureFrom(c) == nil && string(c.RawSubject) == string(c.RawIssuer) {
				seen.rootSent = true
			}
		}
		return seen, nil
	}
	var first csSeen
	for _, v := range []uint16{tls.VersionTLS12, tls.VersionTLS13} {
		seen, err := dial(v)
		if err == nil && thumb != "" && seen.leaf != normalizeThumbprint(thumb) {
			err = fmt.Errorf("leaf %s served, not %s", seen.leaf, normalizeThumbprint(thumb))
		}
		if err == nil && seen.version != tls.VersionName(v) {
			err = fmt.Errorf("negotiated %s", seen.version)
		}
		csLine(t, fmt.Sprintf("handshake %s leaf=%s chain=%d root_sent=%v", tls.VersionName(v), seen.leaf, seen.chain, seen.rootSent), err)
		first = seen
	}
	if s := os.Getenv("PGVIGIL_CS_PARALLEL"); s != "" {
		n, err := strconv.Atoi(s)
		if err != nil || n < 1 || n > 256 {
			t.Fatalf("PGVIGIL_CS_PARALLEL %q: 1..256", s)
		}
		var wg sync.WaitGroup
		var okN, badN atomic.Int64
		var firstErr atomic.Value
		start := make(chan struct{})
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				v := uint16(tls.VersionTLS13)
				if i%2 == 1 {
					v = tls.VersionTLS12
				}
				<-start
				if _, err := dial(v); err != nil {
					badN.Add(1)
					firstErr.CompareAndSwap(nil, err.Error())
					return
				}
				okN.Add(1)
			}(i)
		}
		close(start)
		wg.Wait()
		var perr error
		if badN.Load() > 0 {
			perr = fmt.Errorf("%d failed, the first: %v", badN.Load(), firstErr.Load())
		}
		csLine(t, fmt.Sprintf("parallel %d handshakes=%d", n, okN.Load()), perr)
	}
	if renew != "" {
		fmt.Printf("CS first leaf=%s\n", first.leaf)
		if err := os.WriteFile(renew+".first", []byte(first.leaf), 0o600); err != nil {
			t.Fatal(err)
		}
		var want string
		for waited := 0; waited < 180; waited++ {
			if b, err := os.ReadFile(renew); err == nil && strings.TrimSpace(string(b)) != "" {
				want = normalizeThumbprint(string(b))
				break
			}
			time.Sleep(time.Second)
		}
		if want == "" {
			csLine(t, "renew", errors.New("the renewal file did not appear within 180 s"))
			return
		}
		began, tries, fails := time.Now(), 0, 0
		for time.Since(began) < 90*time.Second {
			tries++
			seen, err := dial(tls.VersionTLS13)
			if err != nil {
				fails++
			} else if seen.leaf == want {
				var ferr error
				if fails > 0 {
					ferr = fmt.Errorf("%d handshake(s) failed while it waited", fails)
				}
				csLine(t, fmt.Sprintf("renewed leaf=%s after=%ds handshakes=%d", seen.leaf, int(time.Since(began).Seconds()), tries), ferr)
				return
			}
			time.Sleep(2 * time.Second)
		}
		csLine(t, "renew", fmt.Errorf("leaf %s still served after 90 s (%d handshakes, %d failed); %s expected", first.leaf, tries, fails, want))
	}
}

var (
	modadvapi32CS     = windows.NewLazySystemDLL("advapi32.dll")
	procLogonUserCS   = modadvapi32CS.NewProc("LogonUserW")
	procImpersonateCS = modadvapi32CS.NewProc("ImpersonateLoggedOnUser")
)

func TestCertstoreProofAsUser(t *testing.T) {
	account, pass, thumb, expect := os.Getenv("PGVIGIL_CS_ASUSER"), os.Getenv("PGVIGIL_CS_ASPASS"), os.Getenv("PGVIGIL_CS_THUMB"), os.Getenv("PGVIGIL_CS_EXPECT")
	if account == "" {
		t.Skip("PGVIGIL_CS_ASUSER is not set: scripts/proof-certstore-windows.ps1 sets it")
	}
	if thumb == "" || (expect != "refused" && expect != "opens") {
		t.Fatal("PGVIGIL_CS_THUMB and PGVIGIL_CS_EXPECT (refused or opens) are needed")
	}
	location, name, err := parseStoreName(os.Getenv("PGVIGIL_CS_STORE"))
	if err != nil {
		t.Fatal(err)
	}
	const logonInteractive, providerDefault = 2, 0 // LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT
	var tok windows.Token
	if r, _, e := procLogonUserCS.Call(uintptr(unsafe.Pointer(utf16z(account))), uintptr(unsafe.Pointer(utf16z("."))), uintptr(unsafe.Pointer(utf16z(pass))),
		logonInteractive, providerDefault, uintptr(unsafe.Pointer(&tok))); r == 0 {
		t.Fatalf("LogonUser %s: %v", account, e)
	}
	defer func() { _ = tok.Close() }()
	runtime.LockOSThread() // the impersonation is this thread's: everything below runs on it
	defer runtime.UnlockOSThread()
	if r, _, e := procImpersonateCS.Call(uintptr(tok)); r == 0 {
		t.Fatalf("ImpersonateLoggedOnUser: %v", e)
	}
	defer func() {
		if err := windows.RevertToSelf(); err != nil {
			panic(err) // a thread left impersonating must not go back to the runtime
		}
	}()
	who := "?"
	var th windows.Token
	if windows.OpenThreadToken(windows.CurrentThread(), windows.TOKEN_QUERY, true, &th) == nil {
		if tu, err := th.GetTokenUser(); err == nil {
			who = tu.User.Sid.String()
		}
		_ = th.Close()
	}
	sc, err := pick(location, name, thumb, "", time.Now())
	if sc != nil {
		defer sc.close()
	}
	switch {
	case expect == "opens" && err == nil:
		csLine(t, fmt.Sprintf("asuser %s %s opens leaf=%s", account, who, sc.thumbprint), nil)
	case expect == "refused" && err != nil && strings.Contains(err.Error(), "does not open for") && strings.Contains(err.Error(), "-grant-key-access "+normalizeThumbprint(thumb)):
		fmt.Printf("CS asuser refusal: %v\n", err)
		csLine(t, fmt.Sprintf("asuser %s %s refused", account, who), nil)
	default:
		csLine(t, fmt.Sprintf("asuser %s %s expected %s", account, who, expect), fmt.Errorf("got %v", err))
	}
}
