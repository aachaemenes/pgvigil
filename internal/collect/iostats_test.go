package collect

import (
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// pg_stat_io is its own collection at a 5-minute default (its rows were 21.3 of the 25.6 MB an idle
// instance stored a day when dbstats read them every minute), gated on PG16+; the stale check takes
// the default from here (expectedIntervals), so the registry carries it.
func TestIostatsRegistered(t *testing.T) {
	c, ok := Get("iostats")
	if !ok {
		t.Fatal("iostats is not registered")
	}
	if c.DefaultInterval() != 5*time.Minute {
		t.Fatalf("default interval %v, want 5m", c.DefaultInterval())
	}
	if ok, why := c.Applies(platform.Info{ServerVersionNum: 150000}); ok || why == "" {
		t.Fatalf("PG15: applies=%v why=%q, want false with a reason", ok, why)
	}
	if ok, _ := c.Applies(platform.Info{ServerVersionNum: 160000, HasPgStatIO: true}); !ok {
		t.Fatal("PG16 with pg_stat_io: does not apply")
	}
}
