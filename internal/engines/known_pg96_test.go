package engines

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// TestUnknownServerNamesAnOldMajor: before 10 a major was two numbers - 9.6, never 'PostgreSQL 9'.
func TestUnknownServerNamesAnOldMajor(t *testing.T) {
	if got := UnknownServer(&platform.Info{ServerVersionNum: 90624}, nil); !strings.Contains(got, "PostgreSQL 9.6 is older") {
		t.Errorf("9.6.24: %q", got)
	}
	if got := UnknownServer(&platform.Info{ServerVersionNum: 120017}, nil); !strings.Contains(got, "PostgreSQL 12 is older") {
		t.Errorf("12.17: %q", got)
	}
}
