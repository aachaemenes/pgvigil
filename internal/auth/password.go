// Package auth hashes and verifies the web UI's passwords with argon2id.
//
// A hash is stored as a PHC string, $argon2id$v=19$m=<KiB>,t=<passes>,p=<lanes>$<salt>$<hash>
// (both parts base64 without padding), so the cost parameters can rise later while every stored
// hash still verifies with the parameters it was made with.
package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"sync"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"
)

// The cost: the OWASP minimum for argon2id (19 MiB, 2 passes, 1 lane); one verify costs about 20 ms
// and 19 MiB on a current machine, small enough for the server, slow enough against a dump.
const (
	memoryKiB = 19 * 1024
	passes    = 2
	lanes     = 1
	saltLen   = 16
	keyLen    = 32
	// MinPasswordLen is the only password rule: length (NIST SP 800-63B; no composition rules).
	MinPasswordLen = 12
	maxPasswordLen = 256
)

var b64 = base64.RawStdEncoding

// CheckPassword applies the password rule.
func CheckPassword(password string) error {
	n := utf8.RuneCountInString(password)
	switch {
	case n < MinPasswordLen:
		return fmt.Errorf("the password needs at least %d characters", MinPasswordLen)
	case n > maxPasswordLen:
		return fmt.Errorf("the password is longer than %d characters", maxPasswordLen)
	case strings.TrimSpace(password) != password:
		return errors.New("the password starts or ends with a space")
	}
	return nil
}

// Hash makes a fresh salt and returns the PHC string of the password.
func Hash(password string) (string, error) {
	if err := CheckPassword(password); err != nil {
		return "", err
	}
	salt := make([]byte, saltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(password), salt, passes, memoryKiB, lanes, keyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s", argon2.Version, memoryKiB, passes, lanes,
		b64.EncodeToString(salt), b64.EncodeToString(key)), nil
}

// Verify reports whether password matches the PHC string; a string that is not one is an error.
// The comparison is constant time; the work is the stored string's own parameters.
func Verify(encoded, password string) (bool, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[0] != "" || parts[1] != "argon2id" {
		return false, errors.New("not an argon2id hash")
	}
	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil || version != argon2.Version {
		return false, errors.New("unsupported argon2 version")
	}
	var m uint32
	var t uint32
	var p uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &m, &t, &p); err != nil {
		return false, errors.New("malformed argon2 parameters")
	}
	// a stored hash states its own cost; refuse one that would eat the server (a tampered row): 256 MiB at most
	if m == 0 || m > 256*1024 || t == 0 || t > 16 || p == 0 || p > 8 {
		return false, errors.New("argon2 parameters out of range")
	}
	salt, err := b64.DecodeString(parts[4])
	if err != nil {
		return false, errors.New("malformed salt")
	}
	want, err := b64.DecodeString(parts[5])
	if err != nil || len(want) == 0 {
		return false, errors.New("malformed hash")
	}
	got := argon2.IDKey([]byte(password), salt, t, m, p, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1, nil
}

// Dummy is a hash of a random secret nobody knows: verifying an unknown user against it costs the
// same as a real check, so a login's timing does not say whether the name exists. Made on first use,
// so `pgvigil version` pays nothing for it.
func Dummy() string {
	dummyOnce.Do(func() {
		secret := make([]byte, 24)
		if _, err := rand.Read(secret); err != nil {
			panic(err)
		}
		h, err := Hash(b64.EncodeToString(secret))
		if err != nil {
			panic(err)
		}
		dummy = h
	})
	return dummy
}

var (
	dummyOnce sync.Once
	dummy     string
)
