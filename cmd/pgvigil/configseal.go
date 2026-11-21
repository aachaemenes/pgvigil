package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"fmt"

	"golang.org/x/crypto/scrypt"
)

// A configuration export sealed under a password (RELNOTES L155): the header - exportMagic, a version byte, the scrypt
// salt and the GCM nonce - then the payload under AES-256-GCM with the whole header as additional data, so a changed
// byte anywhere, a wrong password and another version are all refused before anything is returned.
const (
	exportMagic   = "PGVIGIL CONFIGURATION EXPORT\n"
	exportVersion = 1
	exportSalt    = 16
	exportNonce   = 12
	// scrypt's cost for version 1 (N 2^15, r 8, p 1: about 32 MB and a fraction of a second per open)
	scryptN, scryptR, scryptP = 1 << 15, 8, 1
)

var errNotExport = errors.New("not a pgvigil configuration export (a file 'pgvigil config export -password-stdin' writes)")

func exportKey(password string, salt []byte) (cipher.AEAD, error) {
	key, err := scrypt.Key([]byte(password), salt, scryptN, scryptR, scryptP, 32)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// sealExport seals plain under password into one file's bytes.
func sealExport(plain []byte, password string) ([]byte, error) {
	if password == "" {
		return nil, errors.New("the export's password is empty")
	}
	head := make([]byte, 0, len(exportMagic)+1+exportSalt+exportNonce)
	head = append(head, exportMagic...)
	head = append(head, exportVersion)
	rnd := make([]byte, exportSalt+exportNonce)
	if _, err := rand.Read(rnd); err != nil {
		return nil, err
	}
	head = append(head, rnd...)
	aead, err := exportKey(password, rnd[:exportSalt])
	if err != nil {
		return nil, err
	}
	return aead.Seal(head, rnd[exportSalt:], plain, head), nil
}

// openExport returns the payload of a sealed export, or nil and why.
func openExport(data []byte, password string) ([]byte, error) {
	headLen := len(exportMagic) + 1 + exportSalt + exportNonce
	if len(data) < headLen+16 || !bytes.HasPrefix(data, []byte(exportMagic)) {
		return nil, errNotExport
	}
	if v := data[len(exportMagic)]; v != exportVersion {
		return nil, fmt.Errorf("a configuration export of version %d: this build reads version %d", v, exportVersion)
	}
	head := data[:headLen]
	salt := head[len(exportMagic)+1 : len(exportMagic)+1+exportSalt]
	aead, err := exportKey(password, salt)
	if err != nil {
		return nil, err
	}
	plain, err := aead.Open(nil, head[len(head)-exportNonce:], data[headLen:], head)
	if err != nil {
		return nil, errors.New("the password does not open this export, or the file was changed after it was written")
	}
	return plain, nil
}
