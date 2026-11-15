package main

// The Windows certificate store as serve's TLS (task B24n, PerformanceMonitor 3.13 Added 17): which certificate a
// -tls-thumbprint or -tls-subject names. This file is PURE and builds everywhere, so every rule and every refusal is a
// unit test with self-signed certificates and no store; certstore_windows.go reads the store and signs with the key,
// certstore_other.go refuses the flags elsewhere. The rules are PerformanceMonitor's (DarlingTlsStore.Select and
// DarlingListenerTls.DnsNameMatchesSan, MIT License, Copyright (c) Erik Darling, Darling Data, LLC):
//   - a thumbprint is an exact match after its spaces and the two directional marks a copy from the certificate
//     dialog brings along are dropped and its case folded; it must name exactly one certificate, with a private key.
//     Its lifetime is judged after (lifetimeError): an expired or not-yet-valid pin is refused with its dates;
//   - a subject is a DNS name, matched against the certificate's dNSName Subject Alternative Names only (never the
//     common name), case-insensitively, one trailing dot ignored; a wildcard only as the whole left-most label,
//     standing for exactly one label. Of the certificates that carry it, those valid now, with the Server
//     Authentication extended key usage and a private key, qualify, newest NotBefore first, then the later NotAfter,
//     then the thumbprint, so the order never depends on the store's; the next one is tried when the newest one's key
//     does not open. A certificate the store holds but Go cannot parse is counted and named in the refusal.
// No key material is read here: a candidate only says whether a private key is associated with it.

import (
	"crypto/sha1" // a thumbprint is the SHA-1 of the DER by definition (the store's own name for it)
	"crypto/x509"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode"
)

// storeCert is one certificate of a store as the selection sees it.
type storeCert struct {
	cert       *x509.Certificate // nil: the store holds it but it does not parse
	thumbprint string            // upper-case hexadecimal SHA-1 of the DER
	hasKey     bool              // a private key is associated (not proof that it opens)
	ref        any               // the reader's own handle (certstore_windows.go: the certificate context)
}

func newStoreCert(der []byte, hasKey bool, ref any) storeCert {
	sum := sha1.Sum(der) // the thumbprint, not a security hash
	c, err := x509.ParseCertificate(der)
	if err != nil {
		c = nil
	}
	return storeCert{cert: c, thumbprint: strings.ToUpper(hex.EncodeToString(sum[:])), hasKey: hasKey, ref: ref}
}

// normalizeThumbprint drops every white space character (unicode.IsSpace, as PerformanceMonitor's char.IsWhiteSpace:
// a thumbprint copied from certlm.msc or a mail may carry a no-break or an em space) and the left-to-right and
// right-to-left marks (certlm.msc's copy carries one), and folds the case.
func normalizeThumbprint(s string) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.IsSpace(r) || r == '\u200e' || r == '\u200f' {
			continue
		}
		b.WriteRune(r)
	}
	return strings.ToUpper(b.String())
}

// parseStoreName reads -tls-store: 'LocalMachine\My' (the default), 'CurrentUser\My'; the store name is one name,
// never a path (a path would read another machine's store, as the service's account).
func parseStoreName(s string) (location, name string, err error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "LocalMachine", "My", nil
	}
	loc, nm, ok := strings.Cut(s, `\`)
	if !ok {
		return "", "", fmt.Errorf("-tls-store %q must be Location\\Name (LocalMachine\\My, CurrentUser\\My)", s)
	}
	switch strings.ToLower(loc) {
	case "localmachine":
		loc = "LocalMachine"
	case "currentuser":
		loc = "CurrentUser"
	default:
		return "", "", fmt.Errorf("-tls-store %q: the location must be LocalMachine or CurrentUser", s)
	}
	if nm == "" || strings.ContainsAny(nm, `\/`) {
		return "", "", fmt.Errorf("-tls-store %q: the store name is one name (My, WebHosting), never a path", s)
	}
	return loc, nm, nil
}

// selectByThumbprint is the one certificate a thumbprint names; label names what asked (-tls-thumbprint, or the
// grant's thumbprint), where the store.
func selectByThumbprint(cands []storeCert, thumbprint, where, label string) (storeCert, error) {
	want := normalizeThumbprint(thumbprint)
	var m []storeCert
	for _, c := range cands {
		if c.thumbprint == want {
			m = append(m, c)
		}
	}
	switch {
	case len(m) == 0:
		return storeCert{}, fmt.Errorf("%s %s matches no certificate in the %s store: check the thumbprint, and that the certificate is in the store location this process reads (not another account's)", label, want, where)
	case len(m) > 1:
		return storeCert{}, fmt.Errorf("%s %s matches %d certificates in the %s store: it must name exactly one", label, want, len(m), where)
	case !m[0].hasKey:
		return storeCert{}, fmt.Errorf("%s %s names a certificate with no private key in the %s store: a TLS server certificate must carry its key", label, want, where)
	case m[0].cert == nil:
		return storeCert{}, fmt.Errorf("%s %s names a certificate in the %s store that does not parse", label, want, where)
	}
	return m[0], nil
}

// lifetimeError refuses a certificate outside its validity at now, with its dates.
func lifetimeError(c storeCert, now time.Time, what string) error {
	switch {
	case !now.Before(c.cert.NotAfter):
		return fmt.Errorf("%s expired at %s (valid from %s): renew it", what, c.cert.NotAfter.UTC().Format(time.RFC3339), c.cert.NotBefore.UTC().Format(time.RFC3339))
	case now.Before(c.cert.NotBefore):
		return fmt.Errorf("%s is not valid until %s", what, c.cert.NotBefore.UTC().Format(time.RFC3339))
	}
	return nil
}

// selectBySubject is every certificate that may serve a DNS name, in the order to try them; never empty without an error.
func selectBySubject(cands []storeCert, dnsName string, now time.Time, where, label string) ([]storeCert, error) {
	unreadable := 0
	var named []storeCert
	for _, c := range cands {
		if c.cert == nil {
			unreadable++
			continue
		}
		for _, san := range c.cert.DNSNames {
			if dnsNameMatchesSAN(san, dnsName) {
				named = append(named, c)
				break
			}
		}
	}
	note := ""
	if unreadable > 0 {
		note = fmt.Sprintf(" %d certificate(s) in the %s store could not be read and were skipped.", unreadable, where)
	}
	if len(named) == 0 {
		return nil, fmt.Errorf("%s %q matches no certificate in the %s store: the name must be a dNSName in the certificate's Subject Alternative Name.%s", label, dnsName, where, note)
	}
	var ok []storeCert
	expired, early, noUsage, noKey := 0, 0, 0, 0
	for _, c := range named {
		switch {
		case !now.Before(c.cert.NotAfter):
			expired++
		case now.Before(c.cert.NotBefore):
			early++
		case !hasServerAuth(c.cert):
			noUsage++
		case !c.hasKey:
			noKey++
		default:
			ok = append(ok, c)
		}
	}
	if len(ok) == 0 {
		return nil, fmt.Errorf("%s %q matches %d certificate(s) in the %s store but none can be served (expired: %d, not yet valid: %d, no Server Authentication usage: %d, no private key: %d).%s",
			label, dnsName, len(named), where, expired, early, noUsage, noKey, note)
	}
	sort.SliceStable(ok, func(i, j int) bool {
		a, b := ok[i].cert, ok[j].cert
		if !a.NotBefore.Equal(b.NotBefore) {
			return a.NotBefore.After(b.NotBefore)
		}
		if !a.NotAfter.Equal(b.NotAfter) {
			return a.NotAfter.After(b.NotAfter)
		}
		return ok[i].thumbprint < ok[j].thumbprint
	})
	return ok, nil
}

// hasServerAuth: the certificate names the Server Authentication extended key usage (one with no extended key usage
// does not count: the usage is asked for by name).
func hasServerAuth(c *x509.Certificate) bool {
	for _, u := range c.ExtKeyUsage {
		if u == x509.ExtKeyUsageServerAuth {
			return true
		}
	}
	return false
}

// dnsNameMatchesSAN: does a dNSName SAN value name host? Case-insensitive, one trailing dot ignored; a wildcard only
// as the whole left-most label, for exactly one label (*.corp.local names a.corp.local, not corp.local nor
// a.b.corp.local); a partial or misplaced wildcard names nothing.
func dnsNameMatchesSAN(san, host string) bool {
	p := strings.TrimSuffix(strings.TrimSpace(san), ".")
	h := strings.TrimSuffix(strings.TrimSpace(host), ".")
	if p == "" || h == "" {
		return false
	}
	if !strings.Contains(p, "*") {
		return strings.EqualFold(p, h)
	}
	if !strings.HasPrefix(p, "*.") || strings.Contains(p[1:], "*") || len(p) == 2 {
		return false
	}
	dot := strings.IndexByte(h, '.')
	if dot <= 0 || dot == len(h)-1 {
		return false
	}
	return strings.EqualFold(p[2:], h[dot+1:])
}

// ---- the key-access grant's pure rules (`pgvigil cert -grant-key-access`; PerformanceMonitor's DarlingTlsKeyAccess) ----

// keyReadMask is FILE_GENERIC_READ, the Read entry certlm.msc's Manage Private Keys and icacls (R) write.
const keyReadMask uint32 = 0x120089

const (
	genericAll  uint32 = 0x10000000
	genericRead uint32 = 0x80000000
)

// isBroadPrincipal: a SID that names many accounts (Everyone, Users, Authenticated Users, the logon kinds, ALL
// SERVICES, Domain Users / Guests / Computers ...): never granted, whatever the operator typed.
func isBroadPrincipal(sid string) bool {
	switch sid {
	case "S-1-1-0", "S-1-5-32-545", "S-1-5-11", "S-1-5-4", "S-1-5-2", "S-1-5-7", "S-1-5-32-546", "S-1-5-6", "S-1-5-3",
		"S-1-5-13", "S-1-5-14", "S-1-5-15", "S-1-5-113", "S-1-5-80-0", "S-1-5-32-547", "S-1-5-32-554", "S-1-5-32-555",
		"S-1-5-32-568", "S-1-5-32-580":
		return true
	}
	if strings.HasPrefix(sid, "S-1-2-") || strings.HasPrefix(sid, "S-1-15-2-") {
		return true
	}
	return strings.HasPrefix(sid, "S-1-5-21-") && (strings.HasSuffix(sid, "-513") || strings.HasSuffix(sid, "-514") || strings.HasSuffix(sid, "-515"))
}

// isServiceIdentity: LocalSystem, LocalService, NetworkService, the local Administrators group, a per-service
// virtual account (NT SERVICE\name, S-1-5-80-x but not ALL SERVICES) and an IIS application pool identity: Windows
// reports some as groups, but each names one service.
func isServiceIdentity(sid string) bool {
	switch sid {
	case "S-1-5-18", "S-1-5-19", "S-1-5-20", "S-1-5-32-544":
		return true
	}
	return (strings.HasPrefix(sid, "S-1-5-80-") && sid != "S-1-5-80-0") || strings.HasPrefix(sid, "S-1-5-82-")
}

// SID_NAME_USE values (LookupAccountSid).
const (
	sidUser           uint32 = 1
	sidGroup          uint32 = 2
	sidAlias          uint32 = 4
	sidWellKnownGroup uint32 = 5
	sidComputer       uint32 = 9
)

// refuseByKind is why a SID that names use may not be granted ("" = it may): one account only.
func refuseByKind(sid string, use uint32) string {
	if isServiceIdentity(sid) || use == sidUser {
		return ""
	}
	switch use {
	case sidGroup, sidAlias, sidWellKnownGroup:
		return "is a group"
	case sidComputer:
		return "is a computer"
	}
	return fmt.Sprintf("is not a user or service account (kind %d)", use)
}

// normalizeMask maps an entry's generic bits to the file rights they mean.
func normalizeMask(m uint32) uint32 {
	if m&genericAll != 0 {
		return 0xFFFFFFFF
	}
	if m&genericRead != 0 {
		return m | keyReadMask
	}
	return m
}

// aceView is one entry of a key's access list as the plan reads it.
type aceView struct {
	allow, deny bool
	inheritOnly bool
	sid         string
	mask        uint32
}

// planGrant is what a grant does to a key's access list for account: "already" (its own entries cover Read, or the
// list is NULL: everyone reads), "deny" (an explicit Deny on it overlaps Read: a Deny wins over any Allow, nothing is
// changed), or "add" (one Read entry).
func planGrant(aces []aceView, nullDACL bool, account string) string {
	if nullDACL {
		return "already"
	}
	var allowed, denied uint32
	for _, a := range aces {
		if a.inheritOnly || a.sid != account {
			continue
		}
		switch {
		case a.allow:
			allowed |= normalizeMask(a.mask)
		case a.deny:
			denied |= normalizeMask(a.mask)
		}
	}
	switch {
	case denied&keyReadMask != 0:
		return "deny"
	case allowed&keyReadMask == keyReadMask:
		return "already"
	}
	return "add"
}
