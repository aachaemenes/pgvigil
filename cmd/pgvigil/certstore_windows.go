//go:build windows

package main

// serve's TLS from the Windows certificate store (task B24n): the store read read-only, the certificate a thumbprint
// or a DNS name names (certstore_select.go's rules), its chain without the root, and its private key used where it
// sits through CNG - CryptAcquireCertificatePrivateKey (CNG only, silent) and NCryptSignHash - so no key bytes are
// ever read, logged or exported. A key that will not sign as TLS needs, an expired, absent or ambiguous certificate:
// serve refuses to start with one sentence (pgvigil fails closed; PerformanceMonitor's loopback degrade is not taken).
// Subject mode re-selects hourly on a background ticker (a renewal is served with no restart); thumbprint mode is a pin.
// `pgvigil cert -grant-key-access` gives ONE account Read on a CNG key (PerformanceMonitor's --grant-cert-key-access).
// [unverified: NCrypt's thread safety on one key handle is not on the pages read: each handle signs under a mutex]

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/asn1"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"os"
	"os/user"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	modncrypt         = windows.NewLazySystemDLL("ncrypt.dll")
	procNCryptSign    = modncrypt.NewProc("NCryptSignHash")
	procNCryptFree    = modncrypt.NewProc("NCryptFreeObject")
	procNCryptGetProp = modncrypt.NewProc("NCryptGetProperty")
	procNCryptSetProp = modncrypt.NewProc("NCryptSetProperty")
	modcrypt32        = windows.NewLazySystemDLL("crypt32.dll")
	procCertGetProp   = modcrypt32.NewProc("CertGetCertificateContextProperty")
	modadvapi32       = windows.NewLazySystemDLL("advapi32.dll")
	procInitAcl       = modadvapi32.NewProc("InitializeAcl")
	procAddAce        = modadvapi32.NewProc("AddAce")
	procAddAllowedEx  = modadvapi32.NewProc("AddAccessAllowedAceEx")
)

const (
	ncryptSilentFlag    = 0x00000040
	ncryptPadPKCS1      = 0x00000002
	ncryptPadPSS        = 0x00000008
	certKeyProvInfoProp = 2  // CERT_KEY_PROV_INFO_PROP_ID
	certKeyContextProp  = 5  // CERT_KEY_CONTEXT_PROP_ID
	certNCryptKeyProp   = 78 // CERT_NCRYPT_KEY_HANDLE_PROP_ID
	nteNotSupported     = 0x80090029
	nteSilentContext    = 0x80090022
	ncryptPersistFlag   = 0x80000000 // NCRYPT_PERSIST_FLAG: the property is stored with the key, not on the handle only
	inheritedAce        = 0x10       // INHERITED_ACE
)

// An NCrypt call returns a 32-bit SECURITY_STATUS: every check reads uint32(r), never the whole register.

// reselectKnob turns PGVIGIL_TLS_RESELECT on in a proof build only (-ldflags "-X main.reselectKnob=on").
var reselectKnob = ""

// the re-select interval of subject mode
func reselectEvery() time.Duration {
	if reselectKnob == "on" {
		if d, err := time.ParseDuration(os.Getenv("PGVIGIL_TLS_RESELECT")); err == nil && d >= 10*time.Second && d <= time.Hour {
			return d
		}
	}
	return time.Hour
}

// whoAmI names the account this thread acts as: the impersonated user's token when the thread has one (os/user's
// Current reads the process token, and caches it), else the process's.
func whoAmI() string {
	tok := windows.GetCurrentProcessToken()
	var th windows.Token
	if windows.OpenThreadToken(windows.CurrentThread(), windows.TOKEN_QUERY, true, &th) == nil {
		defer func() { _ = th.Close() }()
		tok = th
	}
	if tu, err := tok.GetTokenUser(); err == nil {
		if acct, dom, _, err := tu.User.Sid.LookupAccount(""); err == nil {
			return dom + `\` + acct
		}
		return tu.User.Sid.String()
	}
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return "this account"
}

// cryptKeyProvInfo is CRYPT_KEY_PROV_INFO (wincrypt.h), the certificate's CERT_KEY_PROV_INFO_PROP_ID.
type cryptKeyProvInfo struct {
	Container *uint16
	Provider  *uint16
	ProvType  uint32 // 0: a CNG key storage provider; else a CryptoAPI provider type
	Flags     uint32
	NParams   uint32
	Params    uintptr
	KeySpec   uint32
}

// legacyProvider says whether the certificate's key sits in a CryptoAPI (CSP) provider, and its name.
func legacyProvider(ctx *windows.CertContext) (bool, string) {
	var n uint32
	if r, _, _ := procCertGetProp.Call(uintptr(unsafe.Pointer(ctx)), certKeyProvInfoProp, 0, uintptr(unsafe.Pointer(&n))); r == 0 || n < uint32(unsafe.Sizeof(cryptKeyProvInfo{})) {
		return false, ""
	}
	buf := make([]uint64, (n+7)/8) // 8-aligned: the struct holds pointers
	if r, _, _ := procCertGetProp.Call(uintptr(unsafe.Pointer(ctx)), certKeyProvInfoProp, uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&n))); r == 0 {
		return false, ""
	}
	pi := (*cryptKeyProvInfo)(unsafe.Pointer(&buf[0]))
	return pi.ProvType != 0, windows.UTF16PtrToString(pi.Provider)
}

func utf16z(s string) *uint16 {
	p, _ := windows.UTF16PtrFromString(s)
	return p
}

func storeFlags(location string) uint32 {
	f := uint32(windows.CERT_STORE_READONLY_FLAG | windows.CERT_STORE_OPEN_EXISTING_FLAG)
	if location == "CurrentUser" {
		return f | windows.CERT_SYSTEM_STORE_CURRENT_USER
	}
	return f | windows.CERT_SYSTEM_STORE_LOCAL_MACHINE
}

func openStore(location, name string) (windows.Handle, error) {
	h, err := windows.CertOpenStore(windows.CERT_STORE_PROV_SYSTEM_W, 0, 0, storeFlags(location), uintptr(unsafe.Pointer(utf16z(name))))
	if err != nil {
		return 0, fmt.Errorf("the %s\\%s store does not open (read-only, existing stores only): %w", location, name, err)
	}
	return h, nil
}

func ctxDER(c *windows.CertContext) []byte {
	return bytes.Clone(unsafe.Slice(c.EncodedCert, c.Length))
}

func hasKeyProp(c *windows.CertContext) bool {
	for _, id := range []uintptr{certKeyProvInfoProp, certKeyContextProp, certNCryptKeyProp} {
		var n uint32
		r, _, _ := procCertGetProp.Call(uintptr(unsafe.Pointer(c)), id, 0, uintptr(unsafe.Pointer(&n)))
		if r != 0 && n > 0 {
			return true
		}
	}
	return false
}

// readStore lists the store's certificates (their DER and whether a key is associated); no context is kept.
func readStore(location, name string) ([]storeCert, error) {
	h, err := openStore(location, name)
	if err != nil {
		return nil, err
	}
	defer func() { _ = windows.CertCloseStore(h, 0) }()
	var out []storeCert
	var c *windows.CertContext
	for {
		c, err = windows.CertEnumCertificatesInStore(h, c)
		if err != nil || c == nil {
			break
		}
		out = append(out, newStoreCert(ctxDER(c), hasKeyProp(c), nil))
	}
	return out, nil
}

// servedCert is a certificate opened for serving: its chain, its key's handle and the signer over it.
type servedCert struct {
	thumbprint string
	tls        *tls.Certificate
	ctx        *windows.CertContext
	key        windows.Handle
	freeKey    bool
	signer     *ncryptSigner // nil until the key is probed
}

// close frees the key under its signer's lock (a handshake signing at shutdown finishes first; a later one is refused,
// never a freed handle) and then the context.
func (s *servedCert) close() {
	if s.signer != nil {
		s.signer.mu.Lock()
		if s.freeKey && s.signer.key != 0 {
			_, _, _ = procNCryptFree.Call(uintptr(s.signer.key))
		}
		s.signer.key = 0
		s.signer.mu.Unlock()
	} else if s.freeKey && s.key != 0 {
		_, _, _ = procNCryptFree.Call(uintptr(s.key))
	}
	s.key = 0
	if s.ctx != nil {
		_ = windows.CertFreeCertificateContext(s.ctx)
		s.ctx = nil
	}
}

// findContext finds the thumbprint's certificate again and keeps a duplicate of its context.
func findContext(location, name, thumbprint string) (*windows.CertContext, error) {
	h, err := openStore(location, name)
	if err != nil {
		return nil, err
	}
	defer func() { _ = windows.CertCloseStore(h, 0) }()
	var c *windows.CertContext
	for {
		c, err = windows.CertEnumCertificatesInStore(h, c)
		if err != nil || c == nil {
			return nil, fmt.Errorf("certificate %s left the %s\\%s store", thumbprint, location, name)
		}
		if newStoreCert(ctxDER(c), false, nil).thumbprint == thumbprint {
			d := windows.CertDuplicateCertificateContext(c)
			_ = windows.CertFreeCertificateContext(c) // the enumeration's own reference (a break ends the enumeration)
			return d, nil
		}
	}
}

// chainDER is the leaf and its intermediates as Windows builds the chain; the root (a self-signed last element) is
// never sent. A chain that does not build serves the leaf alone.
func chainDER(c *windows.CertContext, leaf []byte) [][]byte {
	out := [][]byte{leaf}
	var cc *windows.CertChainContext
	para := windows.CertChainPara{Size: uint32(unsafe.Sizeof(windows.CertChainPara{}))}
	if err := windows.CertGetCertificateChain(0, c, nil, c.Store, &para, 0, 0, &cc); err != nil || cc == nil {
		return out
	}
	defer windows.CertFreeCertificateChain(cc)
	if cc.ChainCount == 0 {
		return out
	}
	simple := *cc.Chains
	els := unsafe.Slice(simple.Elements, simple.NumElements)
	for i := 1; i < len(els); i++ {
		der := ctxDER(els[i].CertContext)
		if xc, err := x509.ParseCertificate(der); err == nil && bytes.Equal(xc.RawSubject, xc.RawIssuer) && xc.CheckSignatureFrom(xc) == nil {
			break // the root
		}
		out = append(out, der)
	}
	return out
}

// ncryptSigner signs with a CNG key where it sits (crypto.Signer for crypto/tls).
type ncryptSigner struct {
	mu  sync.Mutex
	key windows.Handle
	pub crypto.PublicKey
}

func (s *ncryptSigner) Public() crypto.PublicKey { return s.pub }

func hashAlg(h crypto.Hash) (string, error) {
	switch h {
	case crypto.SHA1:
		return "SHA1", nil
	case crypto.SHA256:
		return "SHA256", nil
	case crypto.SHA384:
		return "SHA384", nil
	case crypto.SHA512:
		return "SHA512", nil
	}
	return "", fmt.Errorf("the Windows store's key does not sign %v", h)
}

func (s *ncryptSigner) Sign(_ io.Reader, digest []byte, opts crypto.SignerOpts) ([]byte, error) {
	var pad unsafe.Pointer
	flags := uintptr(ncryptSilentFlag)
	switch s.pub.(type) {
	case *rsa.PublicKey:
		alg, err := hashAlg(opts.HashFunc())
		if err != nil {
			return nil, err
		}
		if pss, ok := opts.(*rsa.PSSOptions); ok {
			salt := pss.SaltLength
			if salt <= 0 { // EqualsHash (what TLS asks for), and Auto taken as the hash's length
				salt = opts.HashFunc().Size()
			}
			pad = unsafe.Pointer(&struct {
				alg  *uint16
				salt uint32
			}{utf16z(alg), uint32(salt)})
			flags |= ncryptPadPSS
		} else {
			pad = unsafe.Pointer(&struct{ alg *uint16 }{utf16z(alg)})
			flags |= ncryptPadPKCS1
		}
	case *ecdsa.PublicKey:
	default:
		return nil, errors.New("the Windows store's key is neither RSA nor ECDSA")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.key == 0 {
		return nil, errors.New("the Windows store's key is closed: serve is stopping")
	}
	var n uint32
	if r, _, _ := procNCryptSign.Call(uintptr(s.key), uintptr(pad), uintptr(unsafe.Pointer(&digest[0])), uintptr(len(digest)), 0, 0, uintptr(unsafe.Pointer(&n)), flags); uint32(r) != 0 {
		return nil, fmt.Errorf("NCryptSignHash (size): %w", syscall.Errno(uint32(r)))
	}
	sig := make([]byte, n)
	if r, _, _ := procNCryptSign.Call(uintptr(s.key), uintptr(pad), uintptr(unsafe.Pointer(&digest[0])), uintptr(len(digest)), uintptr(unsafe.Pointer(&sig[0])), uintptr(n), uintptr(unsafe.Pointer(&n)), flags); uint32(r) != 0 {
		return nil, fmt.Errorf("NCryptSignHash: %w", syscall.Errno(uint32(r)))
	}
	sig = sig[:n]
	if _, ok := s.pub.(*ecdsa.PublicKey); ok {
		// CNG writes r || s, each half the length; TLS wants ASN.1 DER
		half := len(sig) / 2
		return asn1.Marshal(struct{ R, S *big.Int }{new(big.Int).SetBytes(sig[:half]), new(big.Int).SetBytes(sig[half:])})
	}
	return sig, nil
}

// openServed opens a selected certificate: the context kept, the key's CNG handle (silent: a key that would ask a
// person is refused), and the probe signature TLS 1.3 needs, verified with the leaf's public key.
func openServed(location, name string, c storeCert) (*servedCert, error) {
	ctx, err := findContext(location, name, c.thumbprint)
	if err != nil {
		return nil, err
	}
	var key windows.Handle
	var spec uint32
	var free bool
	if err := windows.CryptAcquireCertificatePrivateKey(ctx, windows.CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG|windows.CRYPT_ACQUIRE_SILENT_FLAG, nil, &key, &spec, &free); err != nil {
		why := err.Error()
		if errors.Is(err, syscall.Errno(nteSilentContext)) {
			why = "the key would ask a person (a password or a smart card): serve cannot answer it"
		}
		legacy := ""
		if yes, prov := legacyProvider(ctx); yes {
			legacy = fmt.Sprintf(" Its key sits in the legacy CryptoAPI provider %q, which serve does not use: re-enrol from a template whose provider is a key storage provider.", prov)
		}
		_ = windows.CertFreeCertificateContext(ctx)
		me := whoAmI()
		return nil, fmt.Errorf("the private key of certificate %s does not open for %s: %s. Give that account Read on the key: pgvigil cert -grant-key-access %s -account \"%s\" (elevated), or certlm.msc > the certificate > All Tasks > Manage Private Keys.%s",
			c.thumbprint, me, why, c.thumbprint, me, legacy)
	}
	sc := &servedCert{thumbprint: c.thumbprint, ctx: ctx, key: key, freeKey: free}
	if spec != windows.CERT_NCRYPT_KEY_SPEC {
		sc.close()
		return nil, fmt.Errorf("the private key of certificate %s is not a CNG key: re-enrol from a template whose provider is a key storage provider", c.thumbprint)
	}
	signer := &ncryptSigner{key: key, pub: c.cert.PublicKey}
	sc.signer = signer
	if err := probeSigner(signer); err != nil {
		sc.close()
		return nil, fmt.Errorf("certificate %s: %w", c.thumbprint, err)
	}
	sc.tls = &tls.Certificate{Certificate: chainDER(ctx, c.cert.Raw), PrivateKey: signer, Leaf: c.cert}
	return sc, nil
}

// probeSigner signs one digest as TLS 1.3 does (RSA: PSS, SHA-256, salt 32; ECDSA: SHA-256) and verifies it.
func probeSigner(s *ncryptSigner) error {
	seed := make([]byte, 32)
	_, _ = rand.Read(seed)
	d := sha256.Sum256(seed)
	const bad = "the key's provider does not sign as TLS 1.3 needs (PSS, salt = hash length): re-enrol on a software key storage provider"
	switch pub := s.pub.(type) {
	case *rsa.PublicKey:
		opts := &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash, Hash: crypto.SHA256}
		sig, err := s.Sign(nil, d[:], opts)
		if err != nil {
			return fmt.Errorf("%s (%v)", bad, err)
		}
		if rsa.VerifyPSS(pub, crypto.SHA256, d[:], sig, opts) != nil {
			return errors.New(bad)
		}
	case *ecdsa.PublicKey:
		sig, err := s.Sign(nil, d[:], crypto.SHA256)
		if err != nil {
			return fmt.Errorf("the key does not sign an ECDSA SHA-256 digest (%v)", err)
		}
		if !ecdsa.VerifyASN1(pub, d[:], sig) {
			return errors.New("the key's ECDSA SHA-256 signature does not verify")
		}
	default:
		return errors.New("the certificate's key is neither RSA nor ECDSA")
	}
	return nil
}

// pick selects and opens: a thumbprint's one certificate, or a subject's first whose key opens.
func pick(location, name, thumbprint, subject string, now time.Time) (*servedCert, error) {
	sc, _, err := pickNotes(location, name, thumbprint, subject, now)
	return sc, err
}

// pickNotes is pick and what serve logs as a warning with it (PerformanceMonitor's fallback and unreadable notes):
// a newer certificate whose key does not open for this account while an older one is served (a renewal's new key not
// granted: served only until the older one expires), and the store's certificates that could not be read.
func pickNotes(location, name, thumbprint, subject string, now time.Time) (*servedCert, []string, error) {
	where := location + `\` + name
	cands, err := readStore(location, name)
	if err != nil {
		return nil, nil, err
	}
	if thumbprint != "" {
		c, err := selectByThumbprint(cands, thumbprint, where, "-tls-thumbprint")
		if err != nil {
			return nil, nil, err
		}
		if err := lifetimeError(c, now, "-tls-thumbprint "+c.thumbprint); err != nil {
			return nil, nil, err
		}
		sc, err := openServed(location, name, c)
		return sc, nil, err
	}
	ordered, err := selectBySubject(cands, subject, now, where, "-tls-subject")
	if err != nil {
		return nil, nil, err
	}
	var notes []string
	unreadable := 0
	for _, c := range cands {
		if c.cert == nil {
			unreadable++
		}
	}
	if unreadable > 0 {
		notes = append(notes, fmt.Sprintf("%d certificate(s) in the %s store could not be read and were skipped", unreadable, where))
	}
	var whys []string
	for _, c := range ordered {
		sc, err := openServed(location, name, c)
		if err == nil {
			if len(whys) > 0 {
				notes = append(notes, fmt.Sprintf("a newer certificate's private key does not open for %s, so the older certificate %s is served until it expires on %s: %s",
					whoAmI(), sc.thumbprint, sc.tls.Leaf.NotAfter.UTC().Format(time.RFC3339), strings.Join(whys, "; ")))
			}
			return sc, notes, nil
		}
		whys = append(whys, err.Error())
	}
	return nil, notes, fmt.Errorf("-tls-subject %q: no qualifying certificate's key opens: %s", subject, strings.Join(whys, "; "))
}

// storeServerTLS is the GetCertificate of a server certificate from the Windows store. Subject mode re-selects on a
// background ticker until ctx ends (GetCertificate only reads an atomic pointer); every handle served stays open until
// then (the hourly re-select bounds them).
func storeServerTLS(ctx context.Context, log *slog.Logger, store, thumbprint, subject string) (func(*tls.ClientHelloInfo) (*tls.Certificate, error), error) {
	location, name, err := parseStoreName(store)
	if err != nil {
		return nil, err
	}
	if (thumbprint == "") == (subject == "") {
		return nil, errors.New("name one certificate: -tls-thumbprint or -tls-subject")
	}
	first, notes, err := pickNotes(location, name, thumbprint, subject, time.Now())
	if err != nil {
		return nil, err
	}
	var cur atomic.Pointer[servedCert]
	cur.Store(first)
	log.Info("serve's certificate from the Windows store", "store", location+`\`+name, "thumbprint", first.thumbprint,
		"subject", first.tls.Leaf.Subject.String(), "not_after", first.tls.Leaf.NotAfter.UTC().Format(time.RFC3339), "chain", len(first.tls.Certificate))
	for _, n := range notes {
		log.Warn("serve's certificate: "+n, "served", first.thumbprint)
	}
	var mu sync.Mutex
	all := []*servedCert{first}
	go func() {
		<-ctx.Done()
		mu.Lock()
		defer mu.Unlock()
		for _, s := range all {
			s.close()
		}
		all = nil
	}()
	if subject != "" {
		every := reselectEvery()
		go func() {
			t := time.NewTicker(every)
			defer t.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-t.C:
				}
				now := time.Now()
				next, notes, err := pickNotes(location, name, "", subject, now)
				served := cur.Load()
				if err != nil {
					if !now.Before(served.tls.Leaf.NotAfter) {
						// the certificate served has expired and nothing newer opens: every client is sent an expired
						// certificate until a newer one's key is granted (the next re-select serves it then)
						log.Error("serve's certificate EXPIRED and is still served: no newer certificate qualifies or its key does not open for this account; grant the newer one's key and the next re-select serves it",
							"served", served.thumbprint, "expired", served.tls.Leaf.NotAfter.UTC().Format(time.RFC3339), "subject", subject, "err", err)
					} else {
						log.Error("serve's certificate: no newer certificate qualifies; the one served stays", "subject", subject, "err", err)
					}
					for _, n := range notes {
						log.Warn("serve's certificate: "+n, "served", served.thumbprint)
					}
					continue
				}
				for _, n := range notes {
					log.Warn("serve's certificate: "+n, "served", next.thumbprint)
				}
				if next.thumbprint == served.thumbprint {
					next.close()
					continue
				}
				mu.Lock()
				if all == nil { // shut down meanwhile
					mu.Unlock()
					next.close()
					return
				}
				all = append(all, next) // the old handle stays open: a handshake may still hold it
				mu.Unlock()
				cur.Store(next)
				log.Info("serve's certificate renewed from the Windows store", "thumbprint", next.thumbprint, "not_after", next.tls.Leaf.NotAfter.UTC().Format(time.RFC3339))
			}
		}()
	}
	return func(*tls.ClientHelloInfo) (*tls.Certificate, error) { return cur.Load().tls, nil }, nil
}

// ---- pgvigil cert -grant-key-access ------------------------------------------------------------------------------

func ncryptGetSD(key windows.Handle) ([]byte, error) {
	prop := utf16z("Security Descr")
	var n uint32
	if r, _, _ := procNCryptGetProp.Call(uintptr(key), uintptr(unsafe.Pointer(prop)), 0, 0, uintptr(unsafe.Pointer(&n)), windows.DACL_SECURITY_INFORMATION); uint32(r) != 0 {
		return nil, syscall.Errno(uint32(r))
	}
	b := make([]byte, n)
	if r, _, _ := procNCryptGetProp.Call(uintptr(key), uintptr(unsafe.Pointer(prop)), uintptr(unsafe.Pointer(&b[0])), uintptr(n), uintptr(unsafe.Pointer(&n)), windows.DACL_SECURITY_INFORMATION); uint32(r) != 0 {
		return nil, syscall.Errno(uint32(r))
	}
	return b[:n], nil
}

// ncryptSetSD writes the key's access list with NCRYPT_PERSIST_FLAG, as PerformanceMonitor does ("a write adds
// Persist so the descriptor is stored with the key"): without it a provider may keep it on the handle only.
func ncryptSetSD(key windows.Handle, sd []byte) error {
	prop := utf16z("Security Descr")
	if r, _, _ := procNCryptSetProp.Call(uintptr(key), uintptr(unsafe.Pointer(prop)), uintptr(unsafe.Pointer(&sd[0])), uintptr(len(sd)), ncryptPersistFlag|windows.DACL_SECURITY_INFORMATION); uint32(r) != 0 {
		return syscall.Errno(uint32(r))
	}
	return nil
}

// aclHeader is ACL's layout (winnt.h) with its revision and size readable (x/sys keeps them unexported).
type aclHeader struct {
	Revision byte
	Sbz1     byte
	Size     uint16
	Count    uint16
	Sbz2     uint16
}

// withReadAce is the DACL with one Allow (Read) entry for sid inserted before its first inherited entry, every other
// entry kept as it was and in its order (PerformanceMonitor's DarlingTlsKeyAccess does the same on the raw descriptor):
// a rebuilt list would re-order a non-canonical one.
func withReadAce(old *windows.ACL, sid *windows.SID) (*windows.ACL, error) {
	hdr := (*aclHeader)(unsafe.Pointer(old))
	rev := uint32(hdr.Revision)
	if rev < 2 {
		rev = 2 // ACL_REVISION
	}
	size := uint32(hdr.Size) + uint32(unsafe.Sizeof(windows.ACCESS_ALLOWED_ACE{})) - 4 + windows.GetLengthSid(sid)
	buf := make([]uint32, (size+3)/4) // DWORD-aligned
	acl := (*windows.ACL)(unsafe.Pointer(&buf[0]))
	if r, _, e := procInitAcl.Call(uintptr(unsafe.Pointer(acl)), uintptr(size), uintptr(rev)); r == 0 {
		return nil, fmt.Errorf("InitializeAcl: %w", e)
	}
	n := uint32(old.AceCount)
	at := n
	for i := uint32(0); i < n; i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(old, i, &ace); err != nil {
			return nil, err
		}
		if ace.Header.AceFlags&inheritedAce != 0 {
			at = i
			break
		}
	}
	add := func(i uint32) error {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(old, i, &ace); err != nil {
			return err
		}
		if r, _, e := procAddAce.Call(uintptr(unsafe.Pointer(acl)), uintptr(rev), 0xFFFFFFFF, uintptr(unsafe.Pointer(ace)), uintptr(ace.Header.AceSize)); r == 0 {
			return fmt.Errorf("AddAce: %w", e)
		}
		return nil
	}
	for i := uint32(0); i < at; i++ {
		if err := add(i); err != nil {
			return nil, err
		}
	}
	if r, _, e := procAddAllowedEx.Call(uintptr(unsafe.Pointer(acl)), uintptr(rev), 0, uintptr(keyReadMask), uintptr(unsafe.Pointer(sid))); r == 0 {
		return nil, fmt.Errorf("AddAccessAllowedAceEx: %w", e)
	}
	for i := at; i < n; i++ {
		if err := add(i); err != nil {
			return nil, err
		}
	}
	return acl, nil
}

// readBackSD reads the key's access list through a new context and a new key handle: what the provider stored, not
// what the writing handle remembers.
func readBackSD(location, name, thumbprint string) ([]byte, error) {
	ctx, err := findContext(location, name, thumbprint)
	if err != nil {
		return nil, err
	}
	defer func() { _ = windows.CertFreeCertificateContext(ctx) }()
	var key windows.Handle
	var spec uint32
	var free bool
	if err := windows.CryptAcquireCertificatePrivateKey(ctx, windows.CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG|windows.CRYPT_ACQUIRE_SILENT_FLAG, nil, &key, &spec, &free); err != nil {
		return nil, err
	}
	if free {
		defer func() { _, _, _ = procNCryptFree.Call(uintptr(key)) }()
	}
	return ncryptGetSD(key)
}

// aclView reads a self-relative descriptor's DACL for planGrant.
func aclView(sdBytes []byte) (sd *windows.SECURITY_DESCRIPTOR, aces []aceView, nullDACL bool, err error) {
	sd = (*windows.SECURITY_DESCRIPTOR)(unsafe.Pointer(&sdBytes[0]))
	dacl, _, err := sd.DACL()
	if err != nil {
		if errors.Is(err, windows.ERROR_OBJECT_NOT_FOUND) {
			return sd, nil, true, nil
		}
		return nil, nil, false, err
	}
	if dacl == nil {
		return sd, nil, true, nil
	}
	for i := uint32(0); i < uint32(dacl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, i, &ace); err != nil {
			return nil, nil, false, err
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		aces = append(aces, aceView{allow: ace.Header.AceType == windows.ACCESS_ALLOWED_ACE_TYPE, deny: ace.Header.AceType == windows.ACCESS_DENIED_ACE_TYPE,
			inheritOnly: ace.Header.AceFlags&windows.INHERIT_ONLY_ACE != 0, sid: sid.String(), mask: uint32(ace.Mask)})
	}
	return sd, aces, false, nil
}

// grantKeyAccess gives ONE account Read on the CNG private key of a LocalMachine certificate. Every refusal comes
// before anything is written, in this order: elevation, the store, the account, the certificate, the key, the Deny.
func grantKeyAccess(store, thumbprint, account string, out, errw io.Writer) error {
	location, name, err := parseStoreName(store)
	if err != nil {
		return err
	}
	if location == "CurrentUser" {
		return errors.New("-grant-key-access reads LocalMachine stores only: a CurrentUser key sits in the elevated administrator's own profile, not the one serve runs as")
	}
	if !windows.GetCurrentProcessToken().IsElevated() {
		return errors.New("-grant-key-access changes the access list of a LocalMachine certificate key: run it from an elevated prompt (Run as administrator)")
	}
	if strings.TrimSpace(account) == "" {
		return errors.New("-account is required: the one account serve runs as (DOMAIN\\user, .\\user, NT SERVICE\\name or a SID)")
	}
	var sid *windows.SID
	var use uint32
	// '.\user' is this machine's user: LookupAccountName's forms are DOMAIN\user and user [unverified whether it reads
	// '.' itself; P5 grants with '.\user'], so the dot becomes the computer name
	lookup := account
	if rest, ok := strings.CutPrefix(account, `.\`); ok {
		if cn, cerr := windows.ComputerName(); cerr == nil {
			lookup = cn + `\` + rest
		}
	}
	if strings.HasPrefix(strings.ToUpper(account), "S-1-") {
		if sid, err = windows.StringToSid(account); err == nil {
			_, _, use, err = sid.LookupAccount("")
		}
	} else {
		sid, _, use, err = windows.LookupSID("", lookup)
	}
	if err != nil {
		return fmt.Errorf("-account %s does not resolve to one account: %w (nothing was changed)", account, err)
	}
	ss := sid.String()
	if isBroadPrincipal(ss) {
		return fmt.Errorf("-account %s (%s) names many accounts: a TLS private key is read by the one account serve runs as (nothing was changed)", account, ss)
	}
	if why := refuseByKind(ss, use); why != "" {
		return fmt.Errorf("-account %s (%s) %s: the grant names one account (nothing was changed)", account, ss, why)
	}
	cands, err := readStore(location, name)
	if err != nil {
		return err
	}
	c, err := selectByThumbprint(cands, thumbprint, location+`\`+name, "thumbprint")
	if err != nil {
		return err
	}
	ctx, err := findContext(location, name, c.thumbprint)
	if err != nil {
		return err
	}
	defer func() { _ = windows.CertFreeCertificateContext(ctx) }()
	var key windows.Handle
	var spec uint32
	var free bool
	if err := windows.CryptAcquireCertificatePrivateKey(ctx, windows.CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG|windows.CRYPT_ACQUIRE_SILENT_FLAG, nil, &key, &spec, &free); err != nil || spec != windows.CERT_NCRYPT_KEY_SPEC {
		return fmt.Errorf("the private key of certificate %s does not open as a CNG key (%v): a legacy CryptoAPI key is not granted here; re-enrol from a template whose provider is a key storage provider (nothing was changed)", c.thumbprint, err)
	}
	if free {
		defer func() { _, _, _ = procNCryptFree.Call(uintptr(key)) }()
	}
	old, err := ncryptGetSD(key)
	if err != nil {
		if errors.Is(err, syscall.Errno(nteNotSupported)) {
			return fmt.Errorf("the key of certificate %s sits in a provider that does not show its access list (a smart card, a TPM or another hardware key): grant access with that provider's own tool (nothing was changed)", c.thumbprint)
		}
		return fmt.Errorf("the key's access list does not read: %w (nothing was changed)", err)
	}
	sd, aces, nullDACL, err := aclView(old)
	if err != nil {
		return fmt.Errorf("the key's access list does not parse: %w (nothing was changed)", err)
	}
	switch planGrant(aces, nullDACL, ss) {
	case "already":
		_, _ = fmt.Fprintf(out, "Already granted: %s (%s) can read the private key of certificate %s. Nothing was changed.\n", account, ss, c.thumbprint)
		return nil
	case "deny":
		return fmt.Errorf("%s (%s) has an explicit Deny entry on the private key of certificate %s that covers Read, and a Deny wins over any Allow: remove it (certlm.msc > the certificate > All Tasks > Manage Private Keys) and run this again. Nothing was changed", account, ss, c.thumbprint)
	}
	_, _ = fmt.Fprintf(out, "The key's access list now (the undo: set it back to this in certlm.msc > Manage Private Keys, or remove %s's Read entry): %s\n", account, sd.String())
	dacl, _, err := sd.DACL()
	if err != nil {
		return fmt.Errorf("the key's access list does not read: %w (nothing was changed)", err)
	}
	nacl, err := withReadAce(dacl, sid)
	if err != nil {
		return fmt.Errorf("the new access list: %w (nothing was changed)", err)
	}
	abs, err := windows.NewSecurityDescriptor()
	if err != nil {
		return err
	}
	if err := abs.SetDACL(nacl, true, false); err != nil {
		return err
	}
	// the old descriptor's DACL flags kept: protected (no inheritance from the parent) and auto-inherited
	const keep = windows.SE_DACL_PROTECTED | windows.SE_DACL_AUTO_INHERITED
	if ctl, _, err := sd.Control(); err == nil {
		if err := abs.SetControl(keep, ctl&keep); err != nil {
			return fmt.Errorf("the new access list's flags: %w (nothing was changed)", err)
		}
	}
	rel, err := abs.ToSelfRelative()
	if err != nil {
		return err
	}
	if err := ncryptSetSD(key, bytes.Clone(unsafe.Slice((*byte)(unsafe.Pointer(rel)), rel.Length()))); err != nil {
		return fmt.Errorf("the key's access list was not written: %w", err)
	}
	back, err := readBackSD(location, name, c.thumbprint)
	if err != nil {
		return fmt.Errorf("granted, but the access list does not read back through a new handle: %w", err)
	}
	sd2, aces2, null2, err := aclView(back)
	if err != nil || planGrant(aces2, null2, ss) != "already" {
		return fmt.Errorf("the access list read back does not give %s Read: %v", account, err)
	}
	_, _ = fmt.Fprintf(out, "Granted: %s (%s) has Read on the private key of certificate %s. The access list read back: %s\n", account, ss, c.thumbprint, sd2.String())
	return nil
}
