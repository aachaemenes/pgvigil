package export

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Config is what the verb hands over: the export: section resolved.
type Config struct {
	Name       string
	DSN        string
	StateDir   string
	Dest       Destination
	Settle     time.Duration // a window is first exported this long after it ends
	MaxAge     time.Duration // a run looks this far back
	FinalAfter time.Duration // a window is exported again, as final, once it is this old
	PerRun     int
	MaxBytes   int64
	Timeout    time.Duration
	Carry      []string
	Exclude    []string
	ConfigPath string // named in the lines that give a command
	Version    string
	Out, Err   io.Writer
}

// errIncomplete ends a run that left work it should have done: a window without its manifest, a table given up, an
// hour that aged out. Exit 1.
var errIncomplete = errors.New("the export is not complete (the lines above say what is missing)")

// session is one run's view of the repository: its reading connection, the tables as this configuration carries
// them, and the repository's clock.
type session struct {
	c          Config
	conn       *pgx.Conn
	tables     []Resolved
	now        time.Time
	migrations int
}

func open(ctx context.Context, c Config) (*session, error) {
	conn, err := connect(ctx, c.DSN, c.Timeout)
	if err != nil {
		return nil, err
	}
	s := &session{c: c, conn: conn}
	if err := guard(ctx, conn); err != nil {
		conn.Close(ctx)
		return nil, err
	}
	if s.tables, err = Resolve(ctx, conn, Options{Carry: c.Carry, Exclude: c.Exclude, StateMaxBytes: c.MaxBytes}); err != nil {
		conn.Close(ctx)
		return nil, err
	}
	// the repository's clock, never this host's: the windows are the repository's hours
	if err := conn.QueryRow(ctx, "/* pgvigil-export:clock */ SELECT now(), (SELECT count(*) FROM pgvigil.schema_version)").Scan(&s.now, &s.migrations); err != nil {
		conn.Close(ctx)
		return nil, fmt.Errorf("the repository's clock: %w", err)
	}
	s.now = s.now.UTC()
	return s, nil
}

func (s *session) close() { s.conn.Close(context.Background()) }

// job is one window to export and the pass it is.
type job struct {
	w     Hour
	final bool
}

// destState is what the destination's manifests say: the windows done, the final passes done.
type destState struct {
	done, final map[time.Time]bool
	oldest      time.Time
	newest      time.Time
}

func (s *session) readState(ctx context.Context) (*destState, error) {
	keys, err := s.c.Dest.List(ctx, "_manifests/")
	if err != nil {
		return nil, fmt.Errorf("the destination's manifests (%s): %w", s.c.Dest, err)
	}
	st := &destState{done: map[time.Time]bool{}, final: map[time.Time]bool{}}
	for _, k := range keys {
		w, ok := windowOfKey(k, s.c.Name)
		if !ok {
			continue
		}
		if strings.HasPrefix(k, "_manifests/_final/") {
			st.final[w.From] = true
			continue
		}
		if !strings.HasSuffix(k, ".json") || strings.Count(k, "/") != 1 {
			continue
		}
		st.done[w.From] = true
		if st.oldest.IsZero() || w.From.Before(st.oldest) {
			st.oldest = w.From
		}
		if w.From.After(st.newest) {
			st.newest = w.From
		}
	}
	return st, nil
}

// due lays the hours against the manifests: the windows to export now (oldest first), and the hours that aged out -
// between the export's first window and the reach of a run, with no manifest.
func (s *session) due(st *destState) (todo []job, aged []Hour) {
	reach := s.now.Add(-s.c.MaxAge)
	first := reach.Truncate(time.Hour)
	if !st.oldest.IsZero() && st.oldest.Before(first) {
		first = st.oldest
	}
	for a := first; !a.Add(time.Hour).Add(s.c.Settle).After(s.now); a = a.Add(time.Hour) {
		w := Hour{a, a.Add(time.Hour)}
		if !w.To.After(reach) { // it ended before the reach of a run
			if !st.done[a] {
				aged = append(aged, w)
			}
			continue
		}
		finalDue := !w.To.Add(s.c.FinalAfter).After(s.now)
		switch {
		case !st.done[a]:
			todo = append(todo, job{w, finalDue})
		case finalDue && !st.final[a]:
			todo = append(todo, job{w, true})
		}
	}
	return todo, aged
}

func (s *session) lock() (release func(), held bool, err error) {
	if err := os.MkdirAll(s.c.StateDir, 0o755); err != nil {
		return nil, false, refused("export.state_dir (%s) cannot be made: %v", s.c.StateDir, err)
	}
	release, held, err = lockFile(filepath.Join(s.c.StateDir, "export.lock"))
	if held {
		fmt.Fprintf(s.c.Err, "pgvigil export: another run holds the lock (%s): nothing done\n", filepath.Join(s.c.StateDir, "export.lock"))
	}
	return release, held, err
}

// Run exports every due window, oldest first, at most PerRun of them.
func Run(ctx context.Context, c Config) error {
	s, err := open(ctx, c)
	if err != nil {
		return err
	}
	defer s.close()
	release, held, err := s.lock()
	if err != nil || held {
		return err
	}
	defer release()
	st, err := s.readState(ctx)
	if err != nil {
		return err
	}
	todo, aged := s.due(st)
	more := 0
	if len(todo) > c.PerRun {
		more = len(todo) - c.PerRun
		todo = todo[:c.PerRun]
	}
	incomplete := false
	for _, j := range todo {
		ok, err := s.exportWindow(ctx, j.w, j.final, nil, "")
		if err != nil {
			return err
		}
		incomplete = incomplete || !ok
	}
	fmt.Fprintf(c.Out, "pgvigil export: %d window(s) exported to %s", len(todo), c.Dest)
	if more > 0 {
		fmt.Fprintf(c.Out, "; %d more window(s) due: the next run takes them", more)
	}
	fmt.Fprintln(c.Out)
	for _, w := range aged {
		fmt.Fprintf(c.Err, "pgvigil export: the hour %s has no manifest and is older than max_window_age_hours: pgvigil export -config %s -from %s -to %s (or -gap, to accept the hole)\n",
			isoUTC(w.From), c.ConfigPath, isoUTC(w.From), isoUTC(w.To))
	}
	if incomplete || len(aged) > 0 {
		return errIncomplete
	}
	return nil
}

// RunWindows exports the hours of [from, to) whatever the manifests say (a catch-up, a window done again); only
// names a subset of tables, whose manifest and files carry a mark of their own.
func RunWindows(ctx context.Context, c Config, from, to time.Time, only []string) error {
	s, err := open(ctx, c)
	if err != nil {
		return err
	}
	defer s.close()
	if to.After(s.now) {
		return fmt.Errorf("-to %s has not passed on the repository's clock (%s)", isoUTC(to), isoUTC(s.now))
	}
	var subset map[string]bool
	mark := ""
	if len(only) > 0 {
		subset = map[string]bool{}
		known := map[string]bool{}
		for _, t := range s.tables {
			known[t.Name] = true
		}
		for _, t := range only {
			if !known[t] {
				return fmt.Errorf("-tables: %s is not a table of the repository", t)
			}
			subset[t] = true
		}
		mark = subsetMark(only)
	}
	release, held, err := s.lock()
	if err != nil || held {
		return err
	}
	defer release()
	incomplete := false
	n := 0
	for a := from; a.Before(to); a = a.Add(time.Hour) {
		w := Hour{a, a.Add(time.Hour)}
		ok, err := s.exportWindow(ctx, w, !w.To.Add(c.FinalAfter).After(s.now), subset, mark)
		if err != nil {
			return err
		}
		incomplete = incomplete || !ok
		n++
	}
	fmt.Fprintf(c.Out, "pgvigil export: %d window(s) exported to %s\n", n, c.Dest)
	if incomplete {
		return errIncomplete
	}
	return nil
}

// attempts counts a table's failed reads of a window across runs (state_dir/attempts.json). It is the one thing a
// run keeps beside the destination's manifests; losing it only delays the third run's verdict.
type attempts map[string]map[string]int

func (s *session) attemptsPath() string { return filepath.Join(s.c.StateDir, "attempts.json") }

func (s *session) loadAttempts() attempts {
	a := attempts{}
	if b, err := os.ReadFile(s.attemptsPath()); err == nil {
		_ = json.Unmarshal(b, &a)
	}
	return a
}

func (s *session) saveAttempts(a attempts) {
	for k, v := range a {
		if len(v) == 0 {
			delete(a, k)
		}
	}
	if b, err := json.Marshal(a); err == nil {
		_ = os.WriteFile(s.attemptsPath(), b, 0o644)
	}
}

// giveUpAfter is the number of runs a table may fail a window before the window completes without it.
const giveUpAfter = 3

// exportWindow writes one window: every table's files first, the manifest last and only when no table is still to
// be tried again. complete false = the window has no manifest after this call.
func (s *session) exportWindow(ctx context.Context, w Hour, final bool, only map[string]bool, mark string) (complete bool, err error) {
	c := s.c
	started := time.Now()
	tmp := filepath.Join(c.StateDir, "tmp")
	_ = os.RemoveAll(tmp)
	if err := os.MkdirAll(tmp, 0o755); err != nil {
		return false, refused("export.state_dir (%s) cannot be written: %v", c.StateDir, err)
	}
	defer os.RemoveAll(tmp)

	// a window done again: what the old manifest listed is known before it goes, the manifest goes first (a cut
	// after this point leaves no manifest, so the window counts as not done), the marker with it
	mkey := manifestKey(c.Name, w, mark)
	old := map[string]bool{}
	if b, err := c.Dest.Get(ctx, mkey); err == nil {
		var m Manifest
		if json.Unmarshal(b, &m) == nil {
			for _, t := range m.Tables {
				for _, f := range t.OutputFiles {
					old[f.Path] = true
				}
			}
		}
		if err := c.Dest.Delete(ctx, mkey); err != nil {
			return false, fmt.Errorf("window %s: the old manifest cannot be removed: %w", isoUTC(w.From), err)
		}
	} else if !errors.Is(err, errAbsent) {
		return false, fmt.Errorf("window %s: the destination (%s): %w", isoUTC(w.From), c.Dest, err)
	}
	if mark == "" {
		if err := c.Dest.Delete(ctx, finalKey(c.Name, w)); err != nil {
			return false, fmt.Errorf("window %s: the old marker cannot be removed: %w", isoUTC(w.From), err)
		}
	}

	m := Manifest{ContractVersion: ContractVersion, Repository: c.Name, Window: ManifestWindow{isoUTC(w.From), isoUTC(w.To)},
		Pass: 1, PgvigilVersion: c.Version, SchemaMigrations: s.migrations, StartedAt: isoUTC(time.Now()),
		Tables: []ManifestTable{}, Skipped: []SkippedTable{}, Failed: []FailedTable{}, DroppedColumns: []DroppedColumn{}}
	if final {
		m.Pass = "final"
	}
	att := s.loadAttempts()
	wkey := windowName(c.Name, w) + mark
	retry := 0
	var nfiles int
	var nrows, nbytes int64
	for i := range s.tables {
		r := &s.tables[i]
		if only != nil && !only[r.Name] {
			continue
		}
		if r.Skip != "" {
			m.Skipped = append(m.Skipped, SkippedTable{r.Name, r.Skip})
			continue
		}
		if r.Class != Window && !w.firstOfDay() && r.Name != "instances" && r.Class != Dimension {
			continue // a state table: in the day's first window only
		}
		t0 := time.Now()
		entry, files, err := s.exportTable(ctx, r, w, mark, tmp)
		if err == nil {
			for _, f := range files {
				if err = c.Dest.Upload(ctx, f.Path, f.local); err != nil {
					err = fmt.Errorf("upload to %s: %w", c.Dest, err)
					break
				}
				os.Remove(f.local)
				delete(old, f.Path)
			}
		}
		if err != nil {
			if ctx.Err() != nil {
				return false, ctx.Err()
			}
			if att[wkey] == nil {
				att[wkey] = map[string]int{}
			}
			att[wkey][r.Name]++
			msg := oneLine(err.Error())
			if att[wkey][r.Name] >= giveUpAfter {
				m.Failed = append(m.Failed, FailedTable{r.Name, msg})
				fmt.Fprintf(c.Err, "pgvigil export: window %s: %s failed on %d runs and is left out of the window: %s\n", isoUTC(w.From), r.Name, att[wkey][r.Name], msg)
			} else {
				retry++
				fmt.Fprintf(c.Err, "pgvigil export: window %s: %s failed (run %d of %d before the window completes without it): %s\n", isoUTC(w.From), r.Name, att[wkey][r.Name], giveUpAfter, msg)
			}
			s.saveAttempts(att)
			if s.conn.IsClosed() { // the read cost the connection: a new one for the tables that follow
				if s.conn, err = connect(ctx, c.DSN, c.Timeout); err != nil {
					return false, err
				}
			}
			continue
		}
		entry.ReadMS = time.Since(t0).Milliseconds()
		m.Tables = append(m.Tables, entry)
		for _, d := range r.Dropped {
			m.DroppedColumns = append(m.DroppedColumns, DroppedColumn{r.Name, d.Column, d.Reason})
		}
		nfiles += len(files)
		nrows += entry.RowCount
		nbytes += entry.ByteSize
	}
	if retry > 0 {
		fmt.Fprintf(c.Err, "pgvigil export: window %s is not complete: %d table(s) to try again; its manifest is not written\n", isoUTC(w.From), retry)
		return false, nil
	}
	// the files of the old manifest this pass did not write again (a table with no row now) go before the new
	// manifest names what is there
	for p := range old {
		if err := c.Dest.Delete(ctx, p); err != nil {
			return false, fmt.Errorf("window %s: an old file cannot be removed: %w", isoUTC(w.From), err)
		}
	}
	m.FinishedAt = isoUTC(time.Now())
	body, err := json.MarshalIndent(m, "", " ")
	if err != nil {
		return false, err
	}
	if err := c.Dest.Put(ctx, mkey, body, true); err != nil {
		if errors.Is(err, errExists) {
			return false, fmt.Errorf("window %s: its manifest was written by another run while this one worked: two exports of one repository to one destination are not supported", isoUTC(w.From))
		}
		fmt.Fprintf(c.Err, "pgvigil export: window %s: its files are written and its manifest is not (%s): %v\n", isoUTC(w.From), c.Dest, err)
		return false, nil
	}
	if final && mark == "" {
		if err := c.Dest.Put(ctx, finalKey(c.Name, w), []byte(isoUTC(time.Now())+"\n"), false); err != nil {
			fmt.Fprintf(c.Err, "pgvigil export: window %s: its final manifest is written and its marker is not: %v\n", isoUTC(w.From), err)
			return false, nil
		}
	}
	delete(att, wkey)
	s.saveAttempts(att)
	fmt.Fprintf(c.Out, "window %s .. %s pass %v: %d table(s), %d file(s), %d row(s), %d bytes in %.1f s\n",
		isoUTC(w.From), isoUTC(w.To), m.Pass, len(m.Tables), nfiles, nrows, nbytes, time.Since(started).Seconds())
	return len(m.Failed) == 0, nil
}

func oneLine(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > 300 {
		s = s[:300]
	}
	return s
}

// readSQL is the one statement that reads a table for a window. A window table with an instance_id is read one
// instance at a time inside the statement (the join below), so each read is the partition's own
// (instance_id, time) index path and the bounds prune the partitions; the statement starts with the export's
// comment, which is how a DBA finds it in pg_stat_activity.
func readSQL(r *Resolved, cols []pcol, w Hour) (string, []any) {
	sel := make([]string, len(cols))
	for i, c := range cols {
		sel[i] = c.expr + " AS " + quoteIdent(c.Name)
	}
	list := strings.Join(sel, ", ")
	head := "/* pgvigil-export:" + r.Name + " */ "
	table := "pgvigil." + quoteIdent(r.Name)
	tcol := quoteIdent(r.Time)
	switch {
	case r.Class == Window && r.HasInstance:
		return head + "SELECT x.* FROM pgvigil.instances i CROSS JOIN LATERAL (SELECT " + list + " FROM " + table +
			" WHERE instance_id = i.instance_id AND " + tcol + " >= $1 AND " + tcol + " < $2 ORDER BY " + tcol + ") x", []any{w.From, w.To}
	case r.Class == Window:
		return head + "SELECT " + list + " FROM " + table + " WHERE " + tcol + " >= $1 AND " + tcol + " < $2 ORDER BY " + tcol, []any{w.From, w.To}
	case r.Class == Dimension && !w.firstOfDay():
		return head + "SELECT " + list + " FROM " + table + " WHERE " + tcol + " >= $1", []any{w.From}
	}
	return head + "SELECT " + list + " FROM " + table, nil
}

// exportTable reads one table for one window inside one REPEATABLE READ READ ONLY transaction and writes its
// rows into local files. The transaction has ended before the caller uploads anything.
func (s *session) exportTable(ctx context.Context, r *Resolved, w Hour, mark, tmp string) (ManifestTable, []OutputFile, error) {
	entry := ManifestTable{Table: r.Name, Kind: string(r.Class), TimeColumn: r.Time, KeyColumns: r.Key, OutputFiles: []OutputFile{}}
	if entry.KeyColumns == nil {
		entry.KeyColumns = []string{}
	}
	cols := make([]pcol, len(r.Columns))
	for i, c := range r.Columns {
		cols[i] = mapColumn(r.Name, c)
	}
	sql, args := readSQL(r, cols, w)
	// a deadline of this side as well: a server that stops answering must not hold the run
	tctx, cancel := context.WithTimeout(ctx, s.c.Timeout+time.Minute)
	defer cancel()
	tx, err := s.conn.BeginTx(tctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return entry, nil, err
	}
	fw := newFileWriter(tmp, r.Name, fileBase(r.Name, s.c.Name, w, mark), cols)
	rows, err := tx.Query(tctx, sql, args...)
	if err == nil {
		for rows.Next() {
			var vals []any
			if vals, err = rows.Values(); err != nil {
				break
			}
			if err = fw.add(vals); err != nil {
				break
			}
		}
		rows.Close()
		if err == nil {
			err = rows.Err()
		}
	}
	_ = tx.Rollback(context.Background()) // nothing to commit: the transaction only read
	if err != nil {
		fw.abort()
		return entry, nil, err
	}
	files, err := fw.finish()
	if err != nil {
		fw.abort()
		return entry, nil, err
	}
	for i := range cols {
		entry.Columns = append(entry.Columns, ManifestColumn{cols[i].Name, cols[i].Type, cols[i].parquet, cols[i].note})
	}
	for _, f := range files {
		entry.OutputFiles = append(entry.OutputFiles, f)
		entry.RowCount += f.RowCount
		entry.ByteSize += f.ByteSize
	}
	return entry, files, nil
}

// PlanOut is what -plan prints: nothing is written anywhere.
type PlanOut struct {
	Windows []PlanWindow `json:"windows"`
	AgedOut []PlanWindow `json:"aged_out"`
	Tables  []PlanTable  `json:"tables"`
}

// PlanWindow is a window and, where it is to be exported, its pass.
type PlanWindow struct {
	FromUTC string `json:"from_utc"`
	ToUTC   string `json:"to_utc"`
	Pass    any    `json:"pass,omitempty"`
}

// PlanTable is a table as this configuration carries it.
type PlanTable struct {
	Table      string   `json:"table"`
	Kind       string   `json:"kind"`
	TimeColumn string   `json:"time_column,omitempty"`
	KeyColumns []string `json:"key_columns"`
	Bytes      int64    `json:"bytes"`
	Skipped    string   `json:"skipped,omitempty"`
}

func planWindow(w Hour) PlanWindow { return PlanWindow{FromUTC: isoUTC(w.From), ToUTC: isoUTC(w.To)} }

// Plan prints the due windows and every table's kind. It opens the repository read only and lists the
// destination's manifests; it writes nothing.
func Plan(ctx context.Context, c Config, asJSON bool) error {
	s, err := open(ctx, c)
	if err != nil {
		return err
	}
	defer s.close()
	st, err := s.readState(ctx)
	if err != nil {
		return err
	}
	todo, aged := s.due(st)
	out := PlanOut{Windows: []PlanWindow{}, AgedOut: []PlanWindow{}, Tables: []PlanTable{}}
	for _, j := range todo {
		p := planWindow(j.w)
		p.Pass = 1
		if j.final {
			p.Pass = "final"
		}
		out.Windows = append(out.Windows, p)
	}
	for _, w := range aged {
		out.AgedOut = append(out.AgedOut, planWindow(w))
	}
	for _, r := range s.tables {
		k := r.Key
		if k == nil {
			k = []string{}
		}
		out.Tables = append(out.Tables, PlanTable{r.Name, string(r.Class), r.Time, k, r.Bytes, r.Skip})
	}
	if asJSON {
		return json.NewEncoder(c.Out).Encode(out)
	}
	fmt.Fprintf(c.Out, "%d window(s) due (at most %d a run), %d hour(s) aged out; destination %s\n", len(out.Windows), c.PerRun, len(out.AgedOut), c.Dest)
	for _, w := range out.Windows {
		fmt.Fprintf(c.Out, "  due   %s .. %s pass %v\n", w.FromUTC, w.ToUTC, w.Pass)
	}
	for _, w := range out.AgedOut {
		fmt.Fprintf(c.Out, "  aged  %s .. %s\n", w.FromUTC, w.ToUTC)
	}
	for _, t := range out.Tables {
		if t.Skipped != "" {
			fmt.Fprintf(c.Out, "  %-34s left out: %s\n", t.Table, t.Skipped)
			continue
		}
		fmt.Fprintf(c.Out, "  %-34s %-9s %-14s %d bytes\n", t.Table, t.Kind, t.TimeColumn, t.Bytes)
	}
	return nil
}

// StatusOut is what -status prints, read from the destination's manifests.
type StatusOut struct {
	Repository   string       `json:"repository"`
	Destination  string       `json:"destination"`
	Newest       *PlanWindow  `json:"newest"`
	Missing      []PlanWindow `json:"missing"`
	FinalMissing []PlanWindow `json:"final_missing"`
	AgedOut      []PlanWindow `json:"aged_out"`
}

// Status reads the destination's manifests: the newest window, the hours without a manifest or without their
// final pass, the hours that aged out. Exit 1 when an hour is missing or aged out.
func Status(ctx context.Context, c Config, asJSON bool) error {
	s, err := open(ctx, c)
	if err != nil {
		return err
	}
	defer s.close()
	st, err := s.readState(ctx)
	if err != nil {
		return err
	}
	todo, aged := s.due(st)
	out := StatusOut{Repository: c.Name, Destination: c.Dest.String(), Missing: []PlanWindow{}, FinalMissing: []PlanWindow{}, AgedOut: []PlanWindow{}}
	if !st.newest.IsZero() {
		p := planWindow(Hour{st.newest, st.newest.Add(time.Hour)})
		out.Newest = &p
	}
	for _, j := range todo {
		if st.done[j.w.From] {
			out.FinalMissing = append(out.FinalMissing, planWindow(j.w))
		} else {
			out.Missing = append(out.Missing, planWindow(j.w))
		}
	}
	for _, w := range aged {
		out.AgedOut = append(out.AgedOut, planWindow(w))
	}
	if asJSON {
		if err := json.NewEncoder(c.Out).Encode(out); err != nil {
			return err
		}
	} else {
		newest := "none"
		if out.Newest != nil {
			newest = out.Newest.FromUTC + " .. " + out.Newest.ToUTC
		}
		fmt.Fprintf(c.Out, "%s at %s: newest window %s; %d hour(s) without a manifest, %d without their final pass, %d aged out\n",
			c.Name, c.Dest, newest, len(out.Missing), len(out.FinalMissing), len(out.AgedOut))
		for _, w := range out.AgedOut {
			fmt.Fprintf(c.Out, "  aged out: pgvigil export -config %s -from %s -to %s\n", c.ConfigPath, w.FromUTC, w.ToUTC)
		}
	}
	if len(out.Missing) > 0 || len(out.AgedOut) > 0 {
		return errIncomplete
	}
	return nil
}

// Gap accepts a hole: every hour of [from, to) without a manifest gets a gap manifest (gap true, no table), so
// that it is no longer named as aged out. An hour that has a manifest is left as it is.
func Gap(ctx context.Context, c Config, from, to time.Time) error {
	s, err := open(ctx, c)
	if err != nil {
		return err
	}
	defer s.close()
	release, held, err := s.lock()
	if err != nil || held {
		return err
	}
	defer release()
	st, err := s.readState(ctx)
	if err != nil {
		return err
	}
	n := 0
	for a := from; a.Before(to); a = a.Add(time.Hour) {
		if st.done[a] {
			continue
		}
		w := Hour{a, a.Add(time.Hour)}
		now := isoUTC(time.Now())
		m := Manifest{ContractVersion: ContractVersion, Repository: c.Name, Window: ManifestWindow{isoUTC(w.From), isoUTC(w.To)}, Pass: 1, Gap: true,
			PgvigilVersion: c.Version, SchemaMigrations: s.migrations, StartedAt: now, FinishedAt: now,
			Tables: []ManifestTable{}, Skipped: []SkippedTable{}, Failed: []FailedTable{}, DroppedColumns: []DroppedColumn{}}
		body, err := json.MarshalIndent(m, "", " ")
		if err != nil {
			return err
		}
		if err := c.Dest.Put(ctx, manifestKey(c.Name, w, ""), body, true); err != nil {
			return fmt.Errorf("the gap manifest of %s: %w", isoUTC(w.From), err)
		}
		n++
	}
	fmt.Fprintf(c.Out, "pgvigil export: %d gap manifest(s) written to %s\n", n, c.Dest)
	return nil
}

// ListItem is a line of -tables-list: a table of this repository, its line of the map, and whether this
// configuration exports it.
type ListItem struct {
	Table          string   `json:"table"`
	Class          string   `json:"class"`
	TimeColumn     string   `json:"time_column,omitempty"`
	KeyColumns     []string `json:"key_columns"`
	Carry          string   `json:"carry,omitempty"`
	TextColumns    []string `json:"text_columns,omitempty"`
	DroppedColumns []string `json:"dropped_columns,omitempty"`
	Exported       bool     `json:"exported"`
	Reason         string   `json:"reason,omitempty"`
}

// List prints the catalogue: every table of the repository that is not a partition.
func List(ctx context.Context, c Config, asJSON bool) error {
	s, err := open(ctx, c)
	if err != nil {
		return err
	}
	defer s.close()
	items := make([]ListItem, 0, len(s.tables))
	for _, r := range s.tables {
		it := ListItem{Table: r.Name, Class: string(r.Class), TimeColumn: r.Time, KeyColumns: r.Key, Carry: r.Carry, TextColumns: r.Text, Exported: r.Skip == "", Reason: r.Skip}
		if it.KeyColumns == nil {
			it.KeyColumns = []string{}
		}
		for _, d := range r.Drop {
			it.DroppedColumns = append(it.DroppedColumns, d.Column)
		}
		items = append(items, it)
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Table < items[j].Table })
	if asJSON {
		return json.NewEncoder(c.Out).Encode(items)
	}
	for _, it := range items {
		what := fmt.Sprintf("%-9s %s", it.Class, it.TimeColumn)
		if !it.Exported {
			what = "left out: " + it.Reason
		}
		fmt.Fprintf(c.Out, "%-34s %s\n", it.Table, strings.TrimSpace(what))
	}
	return nil
}

// Check proves the configuration without exporting: the login (read only, unable to write), the map against the
// repository, and the destination by one tiny object written and removed. Every failure is exit 3.
func Check(ctx context.Context, c Config) error {
	s, err := open(ctx, c)
	if err != nil {
		var r *RefusedError
		if errors.As(err, &r) {
			return err
		}
		return refused("%v", err)
	}
	defer s.close()
	if err := os.MkdirAll(c.StateDir, 0o755); err != nil {
		return refused("export.state_dir (%s) cannot be made: %v", c.StateDir, err)
	}
	if err := CheckDestination(ctx, c.Dest); err != nil {
		return refused("%v", err)
	}
	exported := 0
	for _, r := range s.tables {
		if r.Skip == "" {
			exported++
		}
	}
	fmt.Fprintf(c.Out, "pgvigil export -check: ok - %d of %d tables exported, destination %s writable, the repository's clock %s\n", exported, len(s.tables), c.Dest, isoUTC(s.now))
	return nil
}
