package web

// Review C's rows that call what the fold adds (textPolicyWords, remoteRow.QueryText, remoteSafe): their red is their
// absence - the box job's red step runs without this file.

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// B1: 'hash' has its own words - the statement texts are fingerprints - wherever a page says why no text or plan shows
func TestTextPolicyWords(t *testing.T) {
	if w := textPolicyWords("hash"); !strings.Contains(w, `"hash"`) || !strings.Contains(w, "fingerprint") || !strings.Contains(w, "SHA-256") {
		t.Errorf("the hash words: %q", w)
	}
	if w := textPolicyWords("none"); !strings.Contains(w, `"none"`) || strings.Contains(w, "fingerprint") {
		t.Errorf("the none words: %q", w)
	}
}

// B1 (contract 3): readRemote carries the newest loaded bundle's query_text ('hash' when none is known yet)
func TestReadRemoteQueryTextOnAStore(t *testing.T) {
	ctx, pool := remoteStore(t)
	site := fmt.Sprintf("rq%d", time.Now().UnixNano()%1000000000)
	seed := newRemoteSeed(ctx, t, pool)
	seed.site(site, 3600)
	seed.queryText = "none"
	seed.instance(site, "c1", "postgres", "pgnone", time.Now().Add(-10*time.Minute).Truncate(time.Second), 300, nil)
	seed.queryText = ""
	seed.instance(site, "", "postgres", "pgnew", time.Time{}, 0, nil)
	rows, err := readRemote(ctx, pool)
	if err != nil {
		t.Fatal(err)
	}
	by := map[string]string{}
	for _, r := range rows {
		by[r.Name] = r.QueryText
	}
	if by[site+"/pgnone"] != "none" || by[site+"/pgnew"] != "hash" {
		t.Errorf("readRemote's query_text: %v, want none / hash", by)
	}
}

// S1: before 0329 is on the store (a new binary started before 'pgvigil migrate'), the reads that join its views run
// with those views as empty sets - the Summary, the header, Collection dates, the footer and the Collector page answer,
// never 500
func TestRemoteReadsBeforeTheViewsOnAStore(t *testing.T) {
	ctx, pool := remoteStore(t)
	if remoteRelKind(ctx, t, pool) != "" {
		t.Skip("0329's views (or a row's fixture) are on this store: the 'before 0329' reads are V's branch alone's")
	}
	exp := `{"defaults": {}, "instances": {}}`
	for _, c := range []struct {
		name, sql string
		args      []any
	}{
		{"the live read", sqlAckLive, []any{time.Now(), exp, DefaultStaleSecs, noPermission, 0}},
		{"collection dates", sqlCollectionDates, []any{exp, DefaultStaleSecs, 0, []int(nil)}},
		{"the footer", sqlFrameStatus, []any{exp, DefaultStaleSecs, noPermission, "on", true, ""}},
		{"the Collector page's remote part", sqlCollectorRemote, nil},
	} {
		if _, err := pool.Exec(ctx, remoteSafe(c.sql), c.args...); err != nil {
			t.Errorf("%s before 0329: %v", c.name, err)
		}
	}
}
