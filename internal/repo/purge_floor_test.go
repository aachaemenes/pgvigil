package repo

import (
	"context"
	"slices"
	"strings"
	"testing"
	"time"
)

// TestPurgeCandidatesKeepTheFloor: 'pgvigil purge -dry-run' names what purge() drops. purge() keeps the alert log and
// the findings history 90 days at least - its month test takes greatest(p_days, 90) for alert_log and
// greatest(p_days, findings_history_days()) for findings_history (task 403a, S2) - while PurgeCandidates took p_days
// alone, so at -days 30 it named those parents' months 30 to 90 days old that the purge then kept (proof-purge's
// 22008 block: 'would drop 3 partition(s): alert_log_<m>, dbstats_<m>, findings_history_<m>', then '1 partitions and
// rows removed'). On a fresh store, each parent's month 75 days back (wholly older than 30 days, never wholly older
// than 90) and 130 days back (wholly older than 90): the candidates at 30 days name the two 130-day months and neither
// 75-day one, and purge(30) drops exactly those two of the four.
func TestPurgeCandidatesKeepTheFloor(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	r := haJoinFreshStore(ctx, t)
	var in, out string
	if err := r.pool.QueryRow(ctx, `SELECT to_char((now() - interval '75 days') AT TIME ZONE 'UTC', 'YYYYMM'),
	                                       to_char((now() - interval '130 days') AT TIME ZONE 'UTC', 'YYYYMM')`).Scan(&in, &out); err != nil {
		t.Fatal(err)
	}
	parents := []string{"alert_log", "findings_history"}
	for _, p := range parents {
		for _, age := range []string{"75 days", "130 days"} {
			if _, err := r.pool.Exec(ctx, `SELECT pgvigil.ensure_month_partition($1, now() - $2::interval)`, p, age); err != nil {
				t.Fatalf("%s's month %s back: %v", p, age, err)
			}
		}
	}
	floored := func(names []string) []string {
		var got []string
		for _, n := range names {
			for _, p := range parents {
				if strings.HasPrefix(n, p+"_") {
					got = append(got, n)
				}
			}
		}
		slices.Sort(got)
		return got
	}
	want := []string{"alert_log_" + out, "findings_history_" + out}
	cands, err := r.PurgeCandidates(ctx, 30, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := floored(cands); !slices.Equal(got, want) {
		t.Errorf("PurgeCandidates(30) names %v of the alert log and the findings history, want %v (the months of %s are inside purge()'s 90-day floor)", got, want, in)
	}
	if _, err := r.pool.Exec(ctx, `SELECT pgvigil.purge(30)`); err != nil {
		t.Fatal(err)
	}
	var left []string
	for _, p := range parents {
		for _, m := range []string{in, out} {
			var there bool
			if err := r.pool.QueryRow(ctx, `SELECT to_regclass('pgvigil.' || $1) IS NOT NULL`, p+"_"+m).Scan(&there); err != nil {
				t.Fatal(err)
			}
			if there {
				left = append(left, p+"_"+m)
			}
		}
	}
	slices.Sort(left)
	if keep := []string{"alert_log_" + in, "findings_history_" + in}; !slices.Equal(left, keep) {
		t.Errorf("purge(30) left %v of the four months, want %v", left, keep)
	}
}
