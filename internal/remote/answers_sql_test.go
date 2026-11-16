package remote

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"sort"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/repo"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The remote answers against their SQL functions on a fresh store (no Admin rows): the security parts, the counter list
// over several yaml lists, and the transcribed defaults against pgvigil.mssql_counter_defaults. Needs
// PGVIGIL_REPO_TEST_DSN.
func TestAnswersAgainstSQL(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()

	t.Run("defaults", func(t *testing.T) {
		rows, err := pool.Query(ctx, `SELECT object, counter, inst, kind FROM pgvigil.mssql_counter_defaults`)
		if err != nil {
			t.Fatal(err)
		}
		var store []string
		for rows.Next() {
			var o, c, i, k string
			if err := rows.Scan(&o, &c, &i, &k); err != nil {
				t.Fatal(err)
			}
			store = append(store, o+"|"+c+"|"+i+"|"+k)
		}
		var mine []string
		for _, d := range counterDefaults {
			mine = append(mine, d[0]+"|"+d[1]+"||"+d[2])
		}
		sort.Strings(store)
		sort.Strings(mine)
		if !reflect.DeepEqual(store, mine) {
			t.Errorf("the defaults differ: the store %d, the transcription %d\nstore: %v\nmine:  %v", len(store), len(mine), store, mine)
		}
	})

	s, _ := newTestStore(t, t.TempDir(), t.TempDir(), &clock{t: t0})
	id, err := r.EnsureInstanceEngine(ctx, "sqlserver", "answers-"+time.Now().Format("150405.000000"), "onprem", "16.0", 16, false, nil)
	if err != nil {
		t.Fatal(err)
	}
	mid, _ := s.EnsureInstanceEngine(ctx, "sqlserver", inst.Name, "onprem", "16.0", 16, false, nil)

	t.Run("security parts", func(t *testing.T) {
		hub, err := r.MSSQLSettings(ctx, id, "import_mssql_security_parts")
		if err != nil {
			t.Fatal(err)
		}
		mine, err := s.MSSQLSettings(ctx, mid, "import_mssql_security_parts")
		var a, b any
		if err != nil || json.Unmarshal(hub, &a) != nil || json.Unmarshal(mine, &b) != nil || !reflect.DeepEqual(a, b) {
			t.Errorf("the hub %s, the remote %s (%v)", hub, mine, err)
		}
	})

	for name, yaml := range map[string]string{
		"no yaml":    ``,
		"empty list": `[]`,
		"not a list": `{"object": "x"}`,
		"blocked, overridden, added, filtered": `[{"object": "Locks", "counter": "Lock Waits/sec", "action": "remove", "layer": "root"},
			{"object": "Access Methods", "counter": "Forwarded Records/sec", "action": "remove", "layer": "root"},
			{"object": "Access Methods", "counter": "Forwarded Records/sec", "action": "add", "layer": "instance"},
			{"object": " Memory Manager ", "counter": "Free Memory (KB)", "action": "add", "kind": "gauge", "layer": "root"},
			{"object": "Buffer Manager", "counter": "Page reads/sec", "action": "remove", "layer": "root", "kind": "bogus"},
			{"object": "", "counter": "y", "action": "add", "layer": "root"},
			{"object": "z", "counter": "y", "action": "add", "layer": "fleet"}]`,
		"except, kind fallback, an instance's own": `[{"object": "Access Methods", "counter": "Full Scans/sec", "inst": "_Total", "action": "remove", "layer": "root"},
			{"object": "Access Methods", "counter": "Table Lock Escalations/sec", "inst": "_Total", "action": "remove", "layer": "root"},
			{"object": "Access Methods", "counter": "Forwarded Records/sec", "inst": "x", "action": "remove", "layer": "instance"},
			{"object": "Access Methods", "counter": "Forwarded Records/sec", "inst": "y", "action": "remove", "layer": "root"},
			{"object": "Access Methods", "counter": "Index Searches/sec", "inst": " a ", "action": "remove", "layer": "instance"},
			{"object": "Access Methods", "counter": "Index Searches/sec", "inst": "b", "action": "remove", "layer": "root"},
			{"object": "sys.dm_os_process_memory", "counter": "page_fault_count", "action": "add", "layer": "instance"},
			{"object": "Databases", "counter": "Data File(s) Size (KB)", "inst": "tempdb", "action": "add", "layer": "root", "kind": "gauge"},
			{"object": "Access Methods", "counter": "Page Splits/sec", "action": "remove", "layer": "instance"},
			{"object": "General Statistics", "counter": "Processes blocked", "action": "remove", "layer": "root"},
			{"object": "General Statistics", "counter": "Processes blocked", "action": "add", "layer": "root", "kind": "rate"}]`,
	} {
		t.Run("counter list "+name, func(t *testing.T) {
			var y []byte
			if yaml != "" {
				y = []byte(yaml)
			} else {
				y = []byte(`[]`)
			}
			hub, err := r.MSSQLCounterList(ctx, id, y)
			if err != nil {
				t.Fatal(err)
			}
			mine, err := s.MSSQLCounterList(ctx, mid, y)
			if err != nil {
				t.Fatal(err)
			}
			a, b := canonCounters(t, hub), canonCounters(t, mine)
			if !reflect.DeepEqual(a, b) {
				t.Errorf("the hub %d entries, the remote %d", len(a), len(b))
				for i := 0; i < len(a) || i < len(b); i++ {
					var x, z counterEntry
					if i < len(a) {
						x = a[i]
					}
					if i < len(b) {
						z = b[i]
					}
					if !reflect.DeepEqual(x, z) {
						t.Errorf("  first difference at %d: the hub %+v, the remote %+v", i, x, z)
						break
					}
				}
			}
		})
	}
}
