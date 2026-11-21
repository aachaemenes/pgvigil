package web

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// A cloud discovery source that adds the servers it finds by itself: two keys, both
// off - pgvigil.yaml's doors.discovery_auto_add and the source's own switch (0476's auto_add). After each applied read
// of such a source, its auto step takes every proposed server through the page's own approve as auto:<source>, never
// with a tick: first the approve tried and rolled back (what it would refuse or ask a person to tick is left to a
// person, and nothing connects to that server), then the page's Test, then the approve itself. The switch and the
// proposal are read again before each Test and each approve: a switch turned off stops the step.

// autoAddLimit is the servers one auto step adds; autoAddTests the Tests it runs (a failed
// one counts too). The rest wait for the next read.
var (
	autoAddLimit = 25
	autoAddTests = 50
)

// autoAddClaim is the auto step's hold on its source; the step stops autoAddMargin before the claim lapses, so a read
// that takes the source next never runs beside it.
const (
	autoAddClaim  = 10 * time.Minute
	autoAddMargin = time.Minute
)

// autoAddPause, when set (a test's), runs between a proposal's Test and its approve.
var autoAddPause func(id int64)

// autoAddOn says whether a read of src is followed by its auto step.
func autoAddOn(src *sourceRow) bool {
	if src == nil || !src.AutoAdd || !config.DiscoveryAutoAddOn() {
		return false
	}
	return src.Kind == "aws" || src.Kind == "azure" || src.Kind == "gcp"
}

// startAutoAdd starts src's auto step after one of its reads, detached (a Test is 10 s a server: neither a page's read
// nor the hourly loop waits for it), and answers the read's words for it, or nil when src does not add by itself. The
// hourly read's step ends with serve (ctx); a page's outlives the request.
func (s *Server) startAutoAdd(ctx context.Context, src *sourceRow, due bool) any {
	if !autoAddOn(src) {
		return nil
	}
	if !due {
		ctx = context.WithoutCancel(ctx)
	}
	go s.autoAdd(ctx, src)
	return "adding the servers it found by itself: the changes list says what was added"
}

// autoCandidate is a proposed server of the step: its id and, for one whose Test failed, how many times in a row,
// when last and the note it was left with.
type autoCandidate struct {
	ID     int64
	Fails  int
	Tested *time.Time
	Note   *string
}

// autoRetry is when a server whose Test failed fails times in a row is tested again: an hour after, doubling to a
// day, five minutes early (an hourly read finds the first one due).
func autoRetry(tested time.Time, fails int) time.Time {
	h := 24
	if fails >= 1 && fails <= 5 {
		h = 1 << (fails - 1)
	}
	return tested.Add(time.Duration(h)*time.Hour - 5*time.Minute)
}

// autoAdd is one auto step of src, under a claim of its own (the read's was released at its apply, so a read that
// starts meanwhile and this step never both decide a server): each proposed server not gone, those whose Test never
// failed first, oldest first. A refusal of the trial approve or of the approve is left 'needs a person: <its words>',
// a failed Test 'the test failed: <its words>' (tried again an hour later, doubling to a day), a server past
// autoAddLimit adds, autoAddTests Tests or the claim's time 'waits for the next read', a read that failed 'not tried:
// <words>'; import_admin_auto_add keeps those notes and the Tests' counts and writes the step's audit row. It answers
// the counts.
func (s *Server) autoAdd(ctx context.Context, src *sourceRow) map[string]any {
	user := "auto:" + src.Name
	out := map[string]any{"added": 0, "person": 0, "failed": 0, "waiting": 0, "errors": 0}
	holder := fmt.Sprintf("%s:%d:%d:auto", s.hostName(), os.Getpid(), time.Now().UnixNano())
	var started *time.Time
	cctx, ccancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	err := s.actions.audit.QueryRow(cctx, `SELECT pgvigil.import_admin_source_claim($1, $2, $3, false)`, src.Name, holder, int(autoAddClaim.Seconds())).Scan(&started)
	ccancel()
	if err != nil || started == nil {
		s.log.Info("auto-add: not run now: the source's claim is held (a read or a step runs; the next read adds what it finds)", "source", src.Name, "err", err)
		out["skipped"] = "a read of this source, or its step adding what it found, is running: the next read adds what it finds"
		return out
	}
	defer func() {
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		_, _ = s.actions.audit.Exec(rctx, `SELECT pgvigil.import_admin_source_release($1, $2)`, src.Name, holder)
	}()
	deadline := time.Now().Add(autoAddClaim - autoAddMargin)
	cands, err := s.autoAddCandidates(ctx, src.Name)
	if err != nil {
		s.log.Warn("auto-add: the proposals were not read", "source", src.Name, "err", err)
		out["error"] = err.Error()
		return out
	}
	notes := []map[string]any{}
	tested := []map[string]any{}
	added, person, failed, waiting, errs, tests := 0, 0, 0, 0, 0, 0
	stopped := ""
	readFailed := func(note func(string), what string, err error) {
		errs++
		s.log.Warn("auto-add: a read failed", "source", src.Name, "what", what, "err", err)
		note("not tried: " + what + ": " + err.Error() + " (tried again at the next read)")
	}
	for _, c := range cands {
		pid := strconv.FormatInt(c.ID, 10)
		note := func(text string) { notes = append(notes, map[string]any{"proposal_id": pid, "note": text}) }
		if ctx.Err() != nil {
			stopped = "serve stopped"
			break
		}
		if added >= autoAddLimit || tests >= autoAddTests || time.Now().After(deadline) {
			waiting++
			note(fmt.Sprintf("waits for the next read (%d added, %d tested a read at most)", autoAddLimit, autoAddTests))
			continue
		}
		if c.Fails > 0 && c.Tested != nil && time.Now().Before(autoRetry(*c.Tested, c.Fails)) {
			failed++
			if c.Note != nil {
				note(*c.Note)
			} else {
				note(fmt.Sprintf("the test failed %d time(s) in a row (tried again from %s)", c.Fails, autoRetry(*c.Tested, c.Fails).UTC().Format("2006-01-02 15:04 UTC")))
			}
			continue
		}
		on, proposed, err := s.autoAddStill(ctx, src.Name, c.ID)
		if err != nil {
			readFailed(note, "the source and the proposal", err)
			continue
		}
		if !on {
			stopped = "the source's switch is off"
			break
		}
		if !proposed {
			continue // decided or gone since the candidates were read: not this step's
		}
		t := s.decideProposal(ctx, user, "", map[string]any{"op": "test", "proposal_id": pid}, true)
		if t.replyErr != nil {
			readFailed(note, "the proposal", t.replyErr)
			continue
		}
		if t.err != nil {
			person++
			note("needs a person: " + t.err.Error())
			continue
		}
		tests++
		ok, _ := t.test["ok"].(bool)
		tested = append(tested, map[string]any{"proposal_id": pid, "ok": ok})
		if !ok {
			failed++
			fails := c.Fails + 1
			note(fmt.Sprintf("the test failed: %v (%d in a row; tried again from %s)", t.test["detail"], fails, autoRetry(time.Now(), fails).UTC().Format("2006-01-02 15:04 UTC")))
			continue
		}
		if autoAddPause != nil {
			autoAddPause(c.ID)
		}
		on, proposed, err = s.autoAddStill(ctx, src.Name, c.ID)
		if err != nil {
			readFailed(note, "the source and the proposal", err)
			continue
		}
		if !on {
			stopped = "the source's switch is off"
			break
		}
		if !proposed {
			continue
		}
		d := s.decideProposal(ctx, user, "", map[string]any{"op": "approve", "proposal_id": pid}, true)
		if d.replyErr != nil {
			readFailed(note, "the proposal", d.replyErr)
			continue
		}
		why := ""
		if d.err != nil {
			why = d.err.Error()
		} else if d.ans.Outcome != "done" {
			why = d.ans.Detail
		}
		if why != "" {
			person++
			note("needs a person: " + why)
			continue
		}
		added++
	}
	out["added"], out["person"], out["failed"], out["waiting"], out["errors"] = added, person, failed, waiting, errs
	pay := map[string]any{"source": src.Name, "notes": notes, "tested": tested, "added": added, "person": person, "failed": failed, "waiting": waiting, "errors": errs}
	if stopped != "" {
		out["stopped"] = stopped
		pay["stopped"] = stopped
	}
	if ans, _, err := s.callImport(ctx, "import_admin_auto_add", pay); err != nil || ans.Outcome != "done" {
		s.log.Warn("auto-add: the step's notes were not kept", "source", src.Name, "err", err, "detail", ans.Detail)
	}
	s.log.Info("auto-add", "source", src.Name, "added", added, "needs a person", person, "test failed", failed, "waits", waiting, "read failed", errs, "stopped", stopped)
	return out
}

// autoAddCandidates: the source's proposed servers not gone - those whose Test never failed (or passed last) first,
// then by their failures in a row - oldest first.
func (s *Server) autoAddCandidates(ctx context.Context, source string) ([]autoCandidate, error) {
	rows, err := s.pool.Query(ctx, `SELECT proposal_id, auto_fails, auto_tested_at, auto_note FROM pgvigil.admin_proposals
	                                 WHERE source = $1 AND state = 'proposed' AND NOT gone ORDER BY auto_fails, first_seen, proposal_id`, source)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[autoCandidate])
}

// autoAddStill reads again whether source still adds what it finds (its switch, its kind) and whether proposal id is
// still its proposed server, not gone; a removed source adds nothing.
func (s *Server) autoAddStill(ctx context.Context, source string, id int64) (on, proposed bool, err error) {
	var auto bool
	var kind string
	var state *string
	var gone *bool
	err = s.pool.QueryRow(ctx, `SELECT s.auto_add, s.kind, p.state, p.gone FROM pgvigil.admin_sources s
	                              LEFT JOIN pgvigil.admin_proposals p ON p.proposal_id = $2 AND p.source = s.name WHERE s.name = $1`, source, id).Scan(&auto, &kind, &state, &gone)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, false, nil
	}
	if err != nil {
		return false, false, err
	}
	return autoAddOn(&sourceRow{Kind: kind, AutoAdd: auto}), state != nil && *state == "proposed" && gone != nil && !*gone, nil
}

// autoLoginHeld: the words why the auto step leaves a proposal to a person for its login, or "". A login with no
// name (the source holds none) would sign in as serve's own operating-system account and its .pgpass - the account
// nobody chose, which the master-user check cannot see; only a SQL Server sign-in by the host's identity (windows,
// entra-identity) is meant to carry none.
func autoLoginHeld(auth, login string) string {
	if login != "" || auth == "windows" || auth == "entra-identity" {
		return ""
	}
	return "the source holds no login: an approve with nothing typed would sign in as serve's own operating-system account - give the source a login, or approve it with one typed"
}

// trialDecision runs the approve pay would make (import_admin_decision) in a transaction it rolls back: the words of
// its refusal (what a person must tick or change), or "" when it would be done. Nothing of it stays, its audit row
// neither.
func (s *Server) trialDecision(ctx context.Context, pay map[string]any) (string, error) {
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	defer cancel()
	tx, err := s.actions.audit.Begin(wctx)
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	b, _ := json.Marshal(pay)
	var out []byte
	if err := tx.QueryRow(wctx, `SELECT pgvigil.import_admin_decision($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		return "", err
	}
	var a importAnswer
	if err := json.Unmarshal(out, &a); err != nil {
		return "", fmt.Errorf("import_admin_decision answered %q", out)
	}
	if a.Outcome == "done" {
		return "", nil
	}
	return a.Detail, nil
}

// roleSuffix is the role a proposal's display name ends with ("db-1 (writer)").
var roleSuffix = regexp.MustCompile(` \((writer|reader|replica|primary|secondary|read_pool)\)$`)

// proposalName is the instance name of a proposal approved with no name typed - the page's own rule
// (admin_instances.ts prefills the same): its display name, else its server, without a role suffix, made safe, 63
// characters at most; cut says the safe name was longer.
func proposalName(display, server string) (name string, cut bool) {
	n := display
	if n == "" {
		n = server
	}
	n = strings.Trim(unsafeName.ReplaceAllString(roleSuffix.ReplaceAllString(n, ""), "-"), "-._@")
	if len(n) > 63 {
		return strings.TrimRight(n[:63], "-._@"), true
	}
	return n, false
}

// uniqueName is name, or - when it was cut or taken - name with a short hash of the proposal's server (its key: one
// server, one name) in its last nine characters, so two servers whose names meet once cut are two instances.
func uniqueName(name string, cut bool, server string, taken func(string) bool) string {
	if !cut && !taken(name) {
		return name
	}
	sum := sha256.Sum256([]byte(server))
	tag := "-" + hex.EncodeToString(sum[:])[:8]
	if len(name) > 63-len(tag) {
		name = strings.TrimRight(name[:63-len(tag)], "-._@")
	}
	return name + tag
}
