package format

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
)

// sigPrefix starts manifest.sig: the scheme, then the standard base64 of the 64-byte Ed25519 signature over
// manifest.json's bytes, then a line end.
const sigPrefix = "ed25519:"

// SignManifest is manifest.sig's content for manifest bytes signed by key.
func SignManifest(key ed25519.PrivateKey, manifest []byte) []byte {
	return []byte(sigPrefix + base64.StdEncoding.EncodeToString(ed25519.Sign(key, manifest)) + "\n")
}

// VerifySignature checks manifest.sig against manifest.json's bytes with the collector's listed public keys (one is
// enough: two are listed while a key is being changed). The manifest holds every file's sha256 and the sums
// file's, so a signature over it covers the whole bundle once Verify has passed.
func VerifySignature(keys [][]byte, manifest, sig []byte) error {
	b64, ok := bytes.CutPrefix(bytes.TrimRight(sig, "\r\n"), []byte(sigPrefix))
	if !ok {
		return errors.New("manifest.sig is not ed25519:<base64>")
	}
	s, err := base64.StdEncoding.DecodeString(string(b64))
	if err != nil || len(s) != ed25519.SignatureSize {
		return errors.New("manifest.sig does not hold one Ed25519 signature")
	}
	if len(keys) == 0 {
		return errors.New("no key to check the signature with")
	}
	for _, k := range keys {
		if len(k) != ed25519.PublicKeySize {
			return fmt.Errorf("a listed key is %d bytes, not %d", len(k), ed25519.PublicKeySize)
		}
		if ed25519.Verify(ed25519.PublicKey(k), manifest, s) {
			return nil
		}
	}
	return errors.New("the signature is not by any listed key of the collector")
}
