package web

// The Deadlocks page of a PostgreSQL instance (task 161; DBA Dash's Deadlocks report, graph and charts): every
// 'deadlock detected' the log reader stored (pgvigil.log_events, kind deadlock) in the range, each taken apart from its
// DETAIL lines - PostgreSQL writes, for every process of the cycle, "Process P waits for MODE on LOCK; blocked by
// process Q." and then "Process P: <statement>" in the same order, the first being the process that found the deadlock
// and was cancelled (the victim) - into participants and the locks between them, drawn as the SQL Server page's graph
// draws (web/src/deadlock_graph.ts); grouped by the statements and relations involved; counted by database, user,
// application and relation.
//
// What the log does not carry is said as such: the holder's own lock mode (a transaction lock's holder holds
// ExclusiveLock on its transaction, any other's is 'a conflicting mode'); the application (not in the prefixes the
// reader takes: it comes from the activity samples, the pid seen within 90 seconds before the deadlock, and is 'not
// sampled' otherwise); the other processes' user and database (the same samples; the deadlock's database otherwise).
// A relation is named from a lock on a relation, a page or a tuple (its OID resolved through the tables collection),
// else from a CONTEXT line where the event keeps one ('while updating tuple (0,2) in relation "t"'), else from the
// statement's target (UPDATE / DELETE FROM / INSERT INTO / FROM ... FOR UPDATE / LOCK), marked 'from the statement'.
// Under the query_text policy 'normalized' the numbers of the DETAIL lines are '?': the processes are then named by
// their place in the cycle; under 'none' the detail is not stored and a deadlock is a time and a victim pid only.
//
//   GET /api/pg/deadlocks?instance=N&from=&to=   deadlocks (the newest 500, each with its processes and resources),
//                                                groups, by_database, by_user, by_application, by_relation, trend

import (
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// pgDlProc is one process of a deadlock in the row shape deadlock_graph.ts's graphFromRows reads.
type pgDlProc struct {
	Process      string  `json:"process"`
	Spid         *int    `json:"spid"`
	Victim       bool    `json:"victim"`
	Login        *string `json:"login"`
	Host         *string `json:"host"`
	Program      *string `json:"program"`
	Database     *string `json:"database"`
	WaitsOn      *string `json:"waits_on"`
	WaitsMode    *string `json:"waits_mode"`
	WaitMS       *int    `json:"wait_ms"`
	WaitResource *string `json:"wait_resource"`
	Statement    *string `json:"statement"`
	Proc         *string `json:"proc"`
	BlockedBy    string  `json:"blocked_by"`
	Relation     *string `json:"relation"`
	RelationFrom *string `json:"relation_from"` // lock | context | statement
	lockKind     string
	lockRel      *pgRelRef
}

type pgDlRef struct {
	Process string  `json:"process"`
	Spid    *int    `json:"spid"`
	Mode    *string `json:"mode"`
}

// pgDlRes is one lock of a deadlock: its kind, the object as the log names it, who holds it and who waits for it.
type pgDlRes struct {
	Type    string    `json:"type"`
	Object  *string   `json:"object"`
	Index   *string   `json:"index"`
	Mode    *string   `json:"mode"`
	Owners  []pgDlRef `json:"owners"`
	Waiters []pgDlRef `json:"waiters"`
}

type pgRelRef struct{ rel, db int64 }

// pgDeadlock is one deadlock taken apart.
type pgDeadlock struct {
	Processes []*pgDlProc `json:"processes"`
	Resources []*pgDlRes  `json:"resources"`
	Parsed    bool        `json:"parsed"` // false: no DETAIL line of the cycle's shape (the policy 'none', or a cut entry)
}

var (
	// "Process 123 waits for ShareLock on transaction 456; blocked by process 789." (numbers '?' under 'normalized')
	dlWaitRE = regexp.MustCompile(`^Process (\d+|\?) waits for (\w+) on (.+?); blocked by process (\d+|\?)\.?$`)
	dlStmtRE = regexp.MustCompile(`^Process (\d+|\?): (.*)$`)
	// the lock tags of DescribeLockTag that carry a relation
	dlRelRE    = regexp.MustCompile(`^(?:extension of |page \S+ of |tuple \(\S+\) of )?relation (\d+|\?) of database (\d+|\?)$`)
	dlCtxRE    = regexp.MustCompile(`(?m)while (?:updating|locking|deleting|inserting index|checking uniqueness of|rechecking updated|inserting) tuple \([^)]*\) in relation "([^"]+)"`)
	dlTargetRE = regexp.MustCompile(`(?is)^\s*(?:with\b.*?\)\s*)?(?:update\s+(?:only\s+)?|delete\s+from\s+(?:only\s+)?|insert\s+into\s+|lock\s+(?:table\s+)?(?:only\s+)?|select\b.*?\bfrom\s+(?:only\s+)?)((?:"[^"]+"|[\w$]+)(?:\.(?:"[^"]+"|[\w$]+))?)`)
	dlNumRE    = regexp.MustCompile(`\b\d+(?:\.\d+)?\b`)
	dlStrRE    = regexp.MustCompile(`'(?:[^']|'')*'`)
	dlSpaceRE  = regexp.MustCompile(`\s+`)
)

func strp(s string) *string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return &s
}

// lockKindOf is the lock tag's kind: transaction, relation, tuple, page, advisory lock, ...
func lockKindOf(tag string) string {
	for _, k := range []string{"virtual transaction", "speculative token", "extension of relation", "advisory lock", "user lock",
		"remote transaction", "applying transaction", "tuple", "page", "relation", "transaction", "object", "pg_database.datfrozenxid"} {
		if strings.HasPrefix(tag, k) {
			return k
		}
	}
	return "lock"
}

// parsePgDeadlock takes a deadlock's DETAIL lines (and a CONTEXT line where the event keeps one) apart. victimPID is the
// pid of the entry (the process that logged the ERROR); statement is the entry's STATEMENT.
func parsePgDeadlock(detail, statement string, victimPID int) pgDeadlock {
	var d pgDeadlock
	var stmts []*pgDlProc
	var cur *pgDlProc
	ctxRel := ""
	if m := dlCtxRE.FindStringSubmatch(detail); m != nil {
		ctxRel = m[1]
	}
	for _, raw := range strings.Split(strings.ReplaceAll(detail, "\r", ""), "\n") {
		l := strings.TrimSpace(raw)
		if strings.HasPrefix(l, "CONTEXT: ") || strings.HasPrefix(l, "HINT: ") {
			cur = nil
			continue
		}
		if m := dlWaitRE.FindStringSubmatch(l); m != nil {
			p := &pgDlProc{WaitsMode: strp(m[2]), WaitResource: strp(m[3]), BlockedBy: m[4], lockKind: lockKindOf(m[3])}
			if n, err := strconv.Atoi(m[1]); err == nil {
				p.Spid = &n
			}
			p.WaitsOn = strp(m[3])
			if rm := dlRelRE.FindStringSubmatch(m[3]); rm != nil {
				rel, e1 := strconv.ParseInt(rm[1], 10, 64)
				db, e2 := strconv.ParseInt(rm[2], 10, 64)
				if e1 == nil && e2 == nil {
					p.lockRel = &pgRelRef{rel, db}
				}
			}
			d.Processes = append(d.Processes, p)
			cur = nil
			continue
		}
		if m := dlStmtRE.FindStringSubmatch(l); m != nil {
			st := m[2]
			p := &pgDlProc{Statement: &st}
			stmts = append(stmts, p)
			cur = p
			continue
		}
		if cur != nil && l != "" { // a statement of several lines
			v := *cur.Statement + "\n" + strings.TrimRight(raw, " \t")
			cur.Statement = &v
		}
	}
	if len(d.Processes) == 0 {
		return d
	}
	d.Parsed = true
	// the statements follow the wait lines in the same order; their pids name them where the log has numbers
	for i, p := range d.Processes {
		if i < len(stmts) {
			p.Statement = stmts[i].Statement
		}
		if p.Spid != nil {
			p.Process = "process " + strconv.Itoa(*p.Spid)
		} else {
			p.Process = "process #" + strconv.Itoa(i+1)
		}
	}
	// blocked by: the pid, or under '?' the next process of the cycle (PostgreSQL prints the cycle in order)
	for i, p := range d.Processes {
		next := d.Processes[(i+1)%len(d.Processes)]
		if n, err := strconv.Atoi(p.BlockedBy); err == nil {
			p.BlockedBy = "process " + strconv.Itoa(n)
		} else {
			p.BlockedBy = next.Process
		}
	}
	// the victim: the entry's own pid, else the first process (the one that found the cycle)
	victim := 0
	for i, p := range d.Processes {
		if p.Spid != nil && *p.Spid == victimPID {
			victim = i
			break
		}
	}
	d.Processes[victim].Victim = true
	if d.Processes[victim].Statement == nil && strings.TrimSpace(statement) != "" {
		st := statement
		d.Processes[victim].Statement = &st
	}
	// the relation of each wait: the lock's own (resolved later), the CONTEXT line's (the victim's wait), the statement's target
	for i, p := range d.Processes {
		switch {
		case p.lockRel != nil:
			from := "lock"
			p.RelationFrom = &from
		case ctxRel != "" && i == victim:
			r, from := ctxRel, "context"
			p.Relation, p.RelationFrom = &r, &from
		case p.Statement != nil:
			if m := dlTargetRE.FindStringSubmatch(*p.Statement); m != nil {
				r, from := strings.ReplaceAll(m[1], `"`, ""), "statement"
				p.Relation, p.RelationFrom = &r, &from
			}
		}
	}
	// the locks: one per lock tag, its waiters and its holders (a transaction's holder holds ExclusiveLock on it)
	byTag := map[string]*pgDlRes{}
	for _, p := range d.Processes {
		tag := deref(p.WaitResource)
		res, ok := byTag[tag]
		if !ok {
			res = &pgDlRes{Type: p.lockKind, Object: p.WaitResource, Owners: []pgDlRef{}, Waiters: []pgDlRef{}}
			byTag[tag] = res
			d.Resources = append(d.Resources, res)
		}
		res.Waiters = append(res.Waiters, pgDlRef{Process: p.Process, Spid: p.Spid, Mode: p.WaitsMode})
		mode := "a conflicting mode"
		if p.lockKind == "transaction" {
			mode = "ExclusiveLock"
		}
		var holderSpid *int
		for _, q := range d.Processes {
			if q.Process == p.BlockedBy {
				holderSpid = q.Spid
			}
		}
		dup := false
		for _, o := range res.Owners {
			if o.Process == p.BlockedBy {
				dup = true
			}
		}
		if !dup {
			res.Owners = append(res.Owners, pgDlRef{Process: p.BlockedBy, Spid: holderSpid, Mode: &mode})
		}
	}
	return d
}

// dlShape is a statement's shape for grouping: literals and numbers as ?, white space folded, the first 300 characters.
func dlShape(s string) string {
	s = dlStrRE.ReplaceAllString(s, "?")
	s = dlNumRE.ReplaceAllString(s, "?")
	s = strings.TrimSpace(dlSpaceRE.ReplaceAllString(s, " "))
	if r := []rune(s); len(r) > 300 {
		s = string(r[:300])
	}
	return s
}

const sqlPgDeadlockEvents = `
SELECT e.snapshot_at, e.event_key, e.pid, e.usename, e.datname, e.client, e.statement, e.detail
  FROM pgvigil.log_events e
 WHERE e.instance_id = $1 AND e.kind = 'deadlock' AND e.snapshot_at >= $2 AND e.snapshot_at < $3
 ORDER BY e.snapshot_at DESC, e.event_key
 LIMIT 501`

// the application, user and database of a participant: the newest activity sample of its pid within 90 s before
const sqlPgDeadlockSamples = `
SELECT x.k, x.pid, s.application_name, s.usename, s.datname
  FROM unnest($2::text[], $3::int[], $4::timestamptz[]) AS x(k, pid, at)
  CROSS JOIN LATERAL (SELECT a.application_name, a.usename, a.datname FROM pgvigil.activity_sample a
                       WHERE a.instance_id = $1 AND a.pid = x.pid
                         AND a.snapshot_at >= x.at - interval '90 seconds' AND a.snapshot_at <= x.at + interval '5 seconds'
                       ORDER BY a.snapshot_at DESC LIMIT 1) s`

const sqlPgDeadlockRels = `
SELECT t.dbid, t.relid, t.schema_name || '.' || t.table_name
  FROM pgvigil.tables t
  JOIN unnest($2::bigint[], $3::bigint[]) AS x(db, rel) ON t.dbid = x.db AND t.relid = x.rel
 WHERE t.instance_id = $1`

// the deadlock counter of pg_stat_database (dbstats: the rise per database, in the window) beside the log's count
const sqlPgDeadlockCounter = `
SELECT coalesce(sum(d.hi - d.lo), 0)::bigint AS counted, count(*) AS databases
  FROM (SELECT s.dbid, s.epoch, max(s.deadlocks) AS hi, min(s.deadlocks) AS lo
          FROM pgvigil.dbstats s
         WHERE s.instance_id = $1 AND s.snapshot_at >= $2 AND s.snapshot_at <= $3
         GROUP BY s.dbid, s.epoch) d`

type pgDlEvent struct {
	At       time.Time   `json:"event_at"`
	Key      string      `json:"event_key"`
	PID      *int        `json:"victim_pid"`
	User     *string     `json:"victim_user"`
	Database *string     `json:"database"`
	Client   *string     `json:"client"`
	Program  *string     `json:"victim_program"`
	VStmt    *string     `json:"victim_statement"`
	Count    int         `json:"process_count"`
	Rels     string      `json:"relations"`
	Modes    string      `json:"lock_modes"`
	Sig      string      `json:"signature"`
	Group    int         `json:"group"`
	Procs    []*pgDlProc `json:"processes"`
	Res      []*pgDlRes  `json:"resources"`
	Parsed   bool        `json:"parsed"`
	stmt     string      // the entry's STATEMENT
}

type dlCount struct {
	Name  string    `json:"name"`
	Count int       `json:"deadlocks"`
	Procs int       `json:"processes"`
	Last  time.Time `json:"last"`
}

type dlGroup struct {
	Group      int       `json:"group"`
	Count      int       `json:"deadlocks"`
	First      time.Time `json:"first"`
	Last       time.Time `json:"last"`
	Statements []string  `json:"statements"`
	Relations  string    `json:"relations"`
	Modes      string    `json:"lock_modes"`
	Databases  string    `json:"databases"`
	Users      string    `json:"users"`
	Sig        string    `json:"signature"`
	Latest     string    `json:"latest_key"`
	LatestAt   time.Time `json:"latest_at"`
}

// PgDeadlocks is GET /api/pg/deadlocks.
func (s *Server) PgDeadlocks(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	ctx := r.Context()
	var engine string
	if err := s.pool.QueryRow(ctx, `SELECT engine FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&engine); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return
	}
	if engine != "postgres" {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("instance %d is a %s instance: its deadlocks are on the SQL Server Deadlocks tab", id, engine))
		return
	}
	rows, err := s.pool.Query(ctx, sqlPgDeadlockEvents, id, from, to)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("deadlocks: %w", err))
		return
	}
	var evs []*pgDlEvent
	for rows.Next() {
		var (
			at                  time.Time
			key                 string
			pid                 *int
			usr, db, cl, st, dt *string
		)
		if err := rows.Scan(&at, &key, &pid, &usr, &db, &cl, &st, &dt); err != nil {
			rows.Close()
			s.reply(w, r, nil, fmt.Errorf("deadlocks: %w", err))
			return
		}
		vp := 0
		if pid != nil {
			vp = *pid
		}
		d := parsePgDeadlock(deref(dt), deref(st), vp)
		e := &pgDlEvent{At: at, Key: key, PID: pid, User: usr, Database: db, Client: cl, Procs: d.Processes, Res: d.Resources, Parsed: d.Parsed, stmt: deref(st)}
		if e.Procs == nil {
			e.Procs, e.Res = []*pgDlProc{}, []*pgDlRes{}
		}
		evs = append(evs, e)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		s.reply(w, r, nil, fmt.Errorf("deadlocks: %w", err))
		return
	}
	more := len(evs) > 500
	if more {
		evs = evs[:500]
	}
	// the participants' application / user / database from the activity samples, the relations' names from the tables
	var ks []string
	var ps []int
	var ats []time.Time
	var dbs, rels []int64
	for _, e := range evs {
		for _, p := range e.Procs {
			if p.Spid != nil {
				ks, ps, ats = append(ks, e.Key), append(ps, *p.Spid), append(ats, e.At)
			}
			if p.lockRel != nil {
				dbs, rels = append(dbs, p.lockRel.db), append(rels, p.lockRel.rel)
			}
		}
	}
	type sample struct{ app, user, db *string }
	samples := map[string]sample{}
	if len(ks) > 0 {
		srows, err := s.pool.Query(ctx, sqlPgDeadlockSamples, id, ks, ps, ats)
		if err != nil {
			s.reply(w, r, nil, fmt.Errorf("samples: %w", err))
			return
		}
		for srows.Next() {
			var k string
			var pid int
			var sm sample
			if err := srows.Scan(&k, &pid, &sm.app, &sm.user, &sm.db); err != nil {
				srows.Close()
				s.reply(w, r, nil, fmt.Errorf("samples: %w", err))
				return
			}
			samples[k+"|"+strconv.Itoa(pid)] = sm
		}
		srows.Close()
	}
	relName := map[pgRelRef]string{}
	if len(rels) > 0 {
		rrows, err := s.pool.Query(ctx, sqlPgDeadlockRels, id, dbs, rels)
		if err != nil {
			s.reply(w, r, nil, fmt.Errorf("relations: %w", err))
			return
		}
		for rrows.Next() {
			var db, rel int64
			var n string
			if err := rrows.Scan(&db, &rel, &n); err != nil {
				rrows.Close()
				s.reply(w, r, nil, fmt.Errorf("relations: %w", err))
				return
			}
			relName[pgRelRef{rel, db}] = n
		}
		rrows.Close()
	}
	notSampled := "not sampled"
	groups := map[string]*dlGroup{}
	var gl []*dlGroup
	byDB, byUser, byApp, byRel := map[string]*dlCount{}, map[string]*dlCount{}, map[string]*dlCount{}, map[string]*dlCount{}
	bump := func(m map[string]*dlCount, name string, at time.Time, procs int) {
		c, ok := m[name]
		if !ok {
			c = &dlCount{Name: name}
			m[name] = c
		}
		c.Count++
		c.Procs += procs
		if at.After(c.Last) {
			c.Last = at
		}
	}
	for _, e := range evs {
		e.Count = len(e.Procs)
		relSet, modeSet, dbSet, userSet, appSet := map[string]bool{}, map[string]bool{}, map[string]bool{}, map[string]bool{}, map[string]bool{}
		var shapes []string
		for _, p := range e.Procs {
			if p.lockRel != nil {
				n, ok := relName[*p.lockRel]
				if !ok {
					n = fmt.Sprintf("relation %d of database %d", p.lockRel.rel, p.lockRel.db)
				}
				p.Relation = &n
			}
			if p.Victim {
				p.Login, p.Database = e.User, e.Database
			}
			if p.Spid != nil {
				if sm, ok := samples[e.Key+"|"+strconv.Itoa(*p.Spid)]; ok {
					p.Program = sm.app
					if p.Login == nil {
						p.Login = sm.user
					}
					if p.Database == nil {
						p.Database = sm.db
					}
				}
			}
			if p.Program == nil {
				p.Program = &notSampled
			}
			if p.Database == nil {
				p.Database = e.Database
			}
			if p.Victim {
				e.Program, e.VStmt = p.Program, p.Statement
			}
			if p.Relation != nil {
				relSet[*p.Relation] = true
			}
			modeSet[deref(p.WaitsMode)+" on "+p.lockKind] = true
			if p.Database != nil {
				dbSet[*p.Database] = true
			}
			if p.Login != nil {
				userSet[*p.Login] = true
			} else {
				userSet["not sampled"] = true
			}
			appSet[deref(p.Program)] = true
			shapes = append(shapes, dlShape(deref(p.Statement)))
		}
		if !e.Parsed {
			// no cycle in the detail: the entry's own statement is the victim's
			e.VStmt = strp(e.stmt)
			shapes = append(shapes, "(no DETAIL lines: the query_text policy none, or an entry cut short)")
		}
		sort.Strings(shapes)
		e.Rels, e.Modes = joinSet(relSet), joinSet(modeSet)
		e.Sig = strings.Join(shapes, " | ") + " || " + e.Rels + " || " + e.Modes
		g, ok := groups[e.Sig]
		if !ok {
			g = &dlGroup{Group: len(gl) + 1, First: e.At, Last: e.At, Statements: shapes, Relations: e.Rels, Modes: e.Modes, Sig: e.Sig,
				Latest: e.Key, LatestAt: e.At}
			groups[e.Sig] = g
			gl = append(gl, g)
		}
		g.Count++
		if e.At.Before(g.First) {
			g.First = e.At
		}
		if e.At.After(g.Last) {
			g.Last, g.Latest, g.LatestAt = e.At, e.Key, e.At
		}
		g.Databases = mergeList(g.Databases, dbSet)
		g.Users = mergeList(g.Users, userSet)
		e.Group = g.Group
		for n := range dbSet {
			bump(byDB, n, e.At, e.Count)
		}
		if len(dbSet) == 0 {
			bump(byDB, "unknown", e.At, e.Count)
		}
		for n := range userSet {
			bump(byUser, n, e.At, e.Count)
		}
		for n := range appSet {
			bump(byApp, n, e.At, e.Count)
		}
		for n := range relSet {
			bump(byRel, n, e.At, e.Count)
		}
		if len(relSet) == 0 {
			bump(byRel, "not named", e.At, e.Count)
		}
	}
	sort.SliceStable(gl, func(i, j int) bool {
		if gl[i].Count != gl[j].Count {
			return gl[i].Count > gl[j].Count
		}
		return gl[i].Last.After(gl[j].Last)
	})
	// the trend: deadlocks per step of the range (an hour's step for a day or more, else 5 minutes)
	step := 5 * time.Minute
	if to.Sub(from) >= 24*time.Hour {
		step = time.Hour
	}
	trend := map[time.Time]int{}
	for _, e := range evs {
		trend[e.At.Truncate(step)]++
	}
	type tp struct {
		At    time.Time `json:"snapshot_at"`
		Count int       `json:"deadlocks"`
	}
	var tl []tp
	for t := from.Truncate(step); !t.After(to); t = t.Add(step) {
		tl = append(tl, tp{t, trend[t]})
		if len(tl) > 2000 {
			break
		}
	}
	var counted, dbn int64
	if err := s.pool.QueryRow(ctx, sqlPgDeadlockCounter, id, from, to).Scan(&counted, &dbn); err != nil {
		s.reply(w, r, nil, fmt.Errorf("counter: %w", err))
		return
	}
	if evs == nil {
		evs = []*pgDlEvent{}
	}
	if gl == nil {
		gl = []*dlGroup{}
	}
	s.reply(w, r, map[string]any{
		"deadlocks": evs, "more": more, "groups": gl, "trend": tl, "step_secs": int(step.Seconds()),
		"by_database": sortedCounts(byDB), "by_user": sortedCounts(byUser), "by_application": sortedCounts(byApp), "by_relation": sortedCounts(byRel),
		"counter": map[string]any{"deadlocks": counted, "databases": dbn},
	}, nil)
}

func joinSet(m map[string]bool) string {
	var l []string
	for k := range m {
		if k != "" {
			l = append(l, k)
		}
	}
	sort.Strings(l)
	return strings.Join(l, ", ")
}

func mergeList(have string, add map[string]bool) string {
	m := map[string]bool{}
	for _, v := range strings.Split(have, ", ") {
		if v != "" {
			m[v] = true
		}
	}
	for k := range add {
		m[k] = true
	}
	return joinSet(m)
}

func sortedCounts(m map[string]*dlCount) []*dlCount {
	l := make([]*dlCount, 0, len(m))
	for _, c := range m {
		l = append(l, c)
	}
	sort.Slice(l, func(i, j int) bool {
		if l[i].Count != l[j].Count {
			return l[i].Count > l[j].Count
		}
		return l[i].Name < l[j].Name
	})
	return l
}
