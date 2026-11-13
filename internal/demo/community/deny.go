package community

import (
	"os"
	"regexp"
	"strings"
)

// MaxBytes caps the stored samples together (gzipped), so the binary does not grow past what the demo is worth.
const MaxBytes = 1 << 20

// ipv4 is a dotted quad of octets 0-255 standing alone (a version like 16.0.4295.3 is not one; an address that ends a
// sentence, 'from 10.20.1.11.', is).
var ipv4 = regexp.MustCompile(`(^|[^0-9.])((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])($|[^0-9.]|\.($|[^0-9]))`)

// generic are the words no stored sample may hold wherever it was captured: a home folder, the box's job folders,
// the proofs' and the capture's own name prefixes.
var generic = []*regexp.Regexp{
	regexp.MustCompile(`(?i)/home/`),
	regexp.MustCompile(`(?i)cloudbox`),
	regexp.MustCompile(`(?i)\bpgcr`),
	regexp.MustCompile(`(?i)\bb1-`),
	regexp.MustCompile(`(?i)\bcapt-`),
}

// DenyEnv names the environment's own words (the capture machine's host name, its cloud project, its lab's name),
// comma-separated: given at capture and test time, never written into this repository.
const DenyEnv = "PGVIGIL_SAMPLE_DENY"

// EnvDeny returns the words of DenyEnv.
func EnvDeny() []string {
	var out []string
	for _, w := range strings.Split(os.Getenv(DenyEnv), ",") {
		if w = strings.TrimSpace(w); len(w) >= 3 {
			out = append(out, w)
		}
	}
	return out
}

// Deny lists what text holds that no sample may hold: an IPv4 address, a generic word, or one of extra (matched
// without case).
func Deny(text []byte, extra []string) []string {
	var hits []string
	if m := ipv4.Find(text); m != nil {
		hits = append(hits, "an IPv4 address: "+strings.Trim(string(m), " \"',;:()[]{}"))
	}
	for _, re := range generic {
		if re.Match(text) {
			hits = append(hits, re.String())
		}
	}
	low := strings.ToLower(string(text))
	for _, w := range extra {
		if strings.Contains(low, strings.ToLower(w)) {
			hits = append(hits, "a denied word ("+mask(w)+")")
		}
	}
	return hits
}

// mask: a denied word said by its first two and last two letters only (the log names no machine).
func mask(w string) string {
	if len(w) <= 4 {
		return strings.Repeat("*", len(w))
	}
	return w[:2] + strings.Repeat("*", len(w)-4) + w[len(w)-2:]
}

// ScrubIPv4 replaces every IPv4 address in s with the word "(address)" (again until none is left: two addresses one
// separator apart share it, so one pass takes every other one).
func ScrubIPv4(s string) string {
	for i := 0; i < 8 && ipv4.MatchString(s); i++ {
		s = scrubOnce(s)
	}
	return s
}

func scrubOnce(s string) string {
	return ipv4.ReplaceAllStringFunc(s, func(m string) string {
		lead, tail := "", ""
		if m != "" && (m[0] < '0' || m[0] > '9') {
			lead, m = m[:1], m[1:]
		}
		// the tail kept: what follows the address (a '.' that ends a sentence and the character after it, or one character)
		for n := len(m); n > 0 && (m[n-1] < '0' || m[n-1] > '9'); n = len(m) {
			tail = m[n-1:] + tail
			m = m[:n-1]
		}
		return lead + "(address)" + tail
	})
}
