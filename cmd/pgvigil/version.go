package main

import (
	"crypto/fips140"
	"fmt"
	"runtime"
)

// versionLine is what `pgvigil version` prints: the release tag, the Go toolchain and platform, and the
// FIPS 140-3 state of this binary. The release's *_fips assets are built with GOFIPS140=v1.0.0, so their
// only cryptography is the Go Cryptographic Module v1.0.0 (CMVP certificate #5247) and FIPS 140-3 mode is
// on from the first instruction: they print "fips140 on (module v1.0.0)". Run with GODEBUG=fips140=only
// (an assessment mode, not for production) a non-approved algorithm errors out and the line says
// "enforced". A plain build prints "fips140 off". The first two words stay "pgvigil <version>" for the
// installers' check.
func versionLine() string {
	fips := "fips140 off"
	if fips140.Enabled() {
		state := "on"
		if fips140.Enforced() {
			state = "on, enforced"
		}
		fips = fmt.Sprintf("fips140 %s (module %s)", state, fips140.Version())
	}
	return fmt.Sprintf("pgvigil %s (%s %s/%s; %s)", version, runtime.Version(), runtime.GOOS, runtime.GOARCH, fips)
}
