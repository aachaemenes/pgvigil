package ingest

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// the rows' caps are the format's (getmax_test.go writes them as numbers so its rows run red on the code before)
func TestGetMaxCapsAreTheFormats(t *testing.T) {
	eq(t, "the manifest cap", format.MaxManifestBytes, rowManifestCap)
	eq(t, "the signature cap", format.MaxSigBytes, rowSigCap)
}
