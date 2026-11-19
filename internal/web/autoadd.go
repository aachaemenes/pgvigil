package web

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// A cloud discovery source that adds the servers it finds by itself (RELNOTES L237, the lead's 05:32): two keys, both
// off - pgvigil.yaml's doors.discovery_auto_add and the source's own switch (0476's auto_add). After each applied read
// of such a source, its auto step gives every proposed server the page's Test and then the page's own approve
// (decideProposal) as auto:<source>, never with a tick, so whatever the approve would ask a person to confirm stays a
// proposal a person decides.

// autoAddLimit is the servers one auto step adds (the lead's 05:32 (4)); the rest wait for the next read.
var autoAddLimit = 25

// autoAddClaim is the auto step's hold on its source: 25 Tests of 10 s and their approves, with room.
const autoAddClaim = 10 * time.Minute

// autoAddOn says whether a read of src is followed by its auto step.
func autoAddOn(src *sourceRow) bool {
	if src == nil || !src.AutoAdd || !config.DiscoveryAutoAddOn() {
		return false
	}
	return src.Kind == "aws" || src.Kind == "azure" || src.Kind == "gcp"
}

// autoAdd is one auto step of src, under a claim of its own (the read's was released at its apply, so a read that
// starts meanwhile and this step never both decide a server): each proposed server not gone, oldest first. A refusal
// of the approve (or of what it reads first) is left 'needs a person: <its words>', a failed Test 'the test failed:
// <its words>', a server past autoAddLimit 'waits for the next read'; import_admin_auto_add keeps those notes and
// writes the step's audit row. It answers the counts.
func (s *Server) autoAdd(ctx context.Context, src *sourceRow) map[string]any {
	user := "auto:" + src.Name
	out := map[string]any{"added": 0, "person": 0, "failed": 0, "waiting": 0}
	holder := fmt.Sprintf("%s:%d:%d:auto", s.hostName(), os.Getpid(), time.Now().UnixNano())
	var started *time.Time
	cctx, ccancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	err := s.actions.audit.QueryRow(cctx, `SELECT pgvigil.import_admin_source_claim($1, $2, $3, false)`, src.Name, holder, int(autoAddClaim.Seconds())).Scan(&started)
	ccancel()
	if err != nil || started == nil {
		s.log.Info("auto-add: not run now: the source's claim is held (a read runs; its own step adds what it finds)", "source", src.Name, "err", err)
		out["skipped"] = "a read of this source is running: its own step adds what it finds"
		return out
	}
	defer func() {
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		_, _ = s.actions.audit.Exec(rctx, `SELECT pgvigil.import_admin_source_release($1, $2)`, src.Name, holder)
	}()
	ids, err := s.autoAddCandidates(ctx, src.Name)
	if err != nil {
		s.log.Warn("auto-add: the proposals were not read", "source", src.Name, "err", err)
		out["error"] = err.Error()
		return out
	}
	notes := []map[string]any{}
	added, person, failed, waiting := 0, 0, 0, 0
	for _, id := range ids {
		pid := strconv.FormatInt(id, 10)
		note := func(text string) { notes = append(notes, map[string]any{"proposal_id": pid, "note": text}) }
		if added >= autoAddLimit {
			waiting++
			note(fmt.Sprintf("waits for the next read (%d a read)", autoAddLimit))
			continue
		}
		t := s.decideProposal(ctx, user, "", map[string]any{"op": "test", "proposal_id": pid})
		if why := decisionWords(t); why != "" {
			person++
			note("needs a person: " + why)
			continue
		}
		if ok, _ := t.test["ok"].(bool); !ok {
			failed++
			note(fmt.Sprintf("the test failed: %v (tried again at the next read)", t.test["detail"]))
			continue
		}
		d := s.decideProposal(ctx, user, "", map[string]any{"op": "approve", "proposal_id": pid})
		why := decisionWords(d)
		if why == "" && d.ans.Outcome != "done" {
			why = d.ans.Detail
		}
		if why != "" {
			person++
			note("needs a person: " + why)
			continue
		}
		added++
	}
	out["added"], out["person"], out["failed"], out["waiting"] = added, person, failed, waiting
	pay := map[string]any{"source": src.Name, "notes": notes, "added": added, "person": person, "failed": failed, "waiting": waiting}
	if ans, _, err := s.callImport(ctx, "import_admin_auto_add", pay); err != nil || ans.Outcome != "done" {
		s.log.Warn("auto-add: the step's notes and audit row were not written", "source", src.Name, "err", err, "detail", ans.Detail)
	}
	s.log.Info("auto-add", "source", src.Name, "added", added, "needs a person", person, "test failed", failed, "waits", waiting)
	return out
}

// autoAddCandidates: the source's proposed servers not gone, oldest first.
func (s *Server) autoAddCandidates(ctx context.Context, source string) ([]int64, error) {
	rows, err := s.pool.Query(ctx, `SELECT proposal_id FROM pgvigil.admin_proposals WHERE source = $1 AND state = 'proposed' AND NOT gone ORDER BY first_seen, proposal_id`, source)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// decisionWords: the words of a decision stopped before its import (a refusal of what it read, or a read that failed).
func decisionWords(d proposalOut) string {
	switch {
	case d.replyErr != nil:
		return d.replyErr.Error()
	case d.err != nil:
		return d.err.Error()
	}
	return ""
}
