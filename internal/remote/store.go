package remote

import (
	"context"
	"crypto/ed25519"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
	"github.com/aachaemenes/pgvigil/internal/store"
)

// the remote store is a whole store.Store: every collector entry point takes it as it takes the repository
var _ store.Store = (*Store)(nil)

// StoreOptions are what a remote collector's store needs beside its state.
type StoreOptions struct {
	Outbox, Site, Collector     string
	QueryText                   string // hash or none
	PgvigilVersion, SchemaLevel string
	Key                         ed25519.PrivateKey // nil: bundles are not signed
	Interval                    time.Duration      // a bundle's window (the collector's interval)
	Now                         func() time.Time   // nil: time.Now
}

// Store is a remote collector's store.Store: what a collector run hands over goes into the instance's open bundle
// (one per instance and interval), and what a run asks is answered from that bundle's newest moved cursor, else the
// state's committed one (S2). CloseInstance ends an instance's interval: the bundle closed and renamed, then its
// cursors committed - a close that fails commits nothing, so the interval is read again under the same seq.
type Store struct {
	mu      sync.Mutex
	st      *State
	o       StoreOptions
	ids     map[int]string             // local instance id -> name
	ident   map[string]format.Instance // the newest identity each instance gave
	open    map[string]*openBundle
	lastEnd map[string]time.Time // where an instance's next window starts
}

type openBundle struct {
	b     *Bundle
	seq   uint64
	moved map[string]format.Cursor
	runs  map[string]*runCount
}

type runCount struct{ runs, failed int }

// NewStore makes the store over a loaded (and recovered) state.
func NewStore(st *State, o StoreOptions) *Store {
	if o.Now == nil {
		o.Now = time.Now
	}
	return &Store{st: st, o: o, ids: map[int]string{}, ident: map[string]format.Instance{}, open: map[string]*openBundle{}, lastEnd: map[string]time.Time{}}
}

// EnsureInstance is EnsureInstanceEngine for a PostgreSQL instance.
func (s *Store) EnsureInstance(ctx context.Context, name, platform, serverVersion string, versionNum int, isReplica bool, tags []string) (int, error) {
	return s.EnsureInstanceEngine(ctx, "postgres", name, platform, serverVersion, versionNum, isReplica, tags)
}

// EnsureInstanceEngine returns the instance's local id and keeps its identity for its bundles' manifests.
func (s *Store) EnsureInstanceEngine(_ context.Context, engine, name, platform, serverVersion string, versionNum int, isReplica bool, tags []string) (int, error) {
	if strings.TrimSpace(name) == "" {
		return 0, fmt.Errorf("remote store: an instance without a name")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	id := s.st.InstanceID(name)
	s.ids[id] = name
	s.ident[name] = format.Instance{Engine: engine, Name: name, Platform: platform, ServerVersion: serverVersion, VersionNum: versionNum, IsReplica: isReplica, Tags: append([]string{}, tags...)}
	return id, nil
}

func (s *Store) name(id int) (string, error) {
	n, ok := s.ids[id]
	if !ok {
		return "", fmt.Errorf("remote store: no instance with id %d", id)
	}
	return n, nil
}

// bundle is the instance's open bundle, opened at its first use in the window: the seq reserved first (state.go), the
// window from where the last one ended (or now) for the collector's interval.
func (s *Store) bundle(name string) (*openBundle, error) {
	if ob := s.open[name]; ob != nil {
		return ob, nil
	}
	id, ok := s.ident[name]
	if !ok {
		return nil, fmt.Errorf("remote store: instance %s has no identity yet", name)
	}
	seq, err := s.st.Reserve(name)
	if err != nil {
		return nil, err
	}
	from, ok := s.lastEnd[name]
	if !ok {
		from = s.o.Now()
	}
	b, err := OpenBundle(BundleOptions{Outbox: s.o.Outbox, Site: s.o.Site, Collector: s.o.Collector, Stream: s.st.Stream, Seq: seq,
		From: from, To: from.Add(s.o.Interval), Instance: id, QueryText: s.o.QueryText, PgvigilVersion: s.o.PgvigilVersion,
		SchemaLevel: s.o.SchemaLevel, Key: s.o.Key})
	if err != nil {
		return nil, err
	}
	ob := &openBundle{b: b, seq: seq, moved: map[string]format.Cursor{}, runs: map[string]*runCount{}}
	s.open[name] = ob
	return ob, nil
}

// cursorLocked is a source's value for the instance: the open bundle's newest moved, else the committed.
func (s *Store) cursorLocked(name, source string) (format.Cursor, bool) {
	if ob := s.open[name]; ob != nil {
		if c, ok := ob.moved[source]; ok {
			return c, true
		}
	}
	return s.st.Cursor(name, source)
}

// Import writes one batch into the instance's open bundle and moves its cursors as the hub's import of it would.
func (s *Store) Import(_ context.Context, instanceID int, collection string, snapshotAt time.Time, rows []map[string]any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	name, err := s.name(instanceID)
	if err != nil {
		return err
	}
	ob, err := s.bundle(name)
	if err != nil {
		return err
	}
	if err := ob.b.AddBatch(collection, snapshotAt, rows); err != nil {
		return err
	}
	for _, c := range cursorMoves(collection, snapshotAt, rows, func(src string) (format.Cursor, bool) { return s.cursorLocked(name, src) }) {
		ob.moved[c.Source] = c
	}
	return nil
}

// count records a run of a collection for its read: a skipped run is no run; any status but ok counts failed.
func (ob *openBundle) count(collection, status string) {
	if status == "skipped" {
		return
	}
	rc := ob.runs[collection]
	if rc == nil {
		rc = &runCount{}
		ob.runs[collection] = rc
	}
	rc.runs++
	if status != "ok" {
		rc.failed++
	}
}

// LogCollection records one run of a collection in the instance's bundle.
func (s *Store) LogCollection(ctx context.Context, instanceID int, collection string, snapshotAt time.Time, d time.Duration, status, note string) error {
	return s.LogCollectionStage(ctx, instanceID, collection, snapshotAt, d, status, note, "")
}

// LogCollectionStage records one run of a collection with the stage it ended in.
func (s *Store) LogCollectionStage(_ context.Context, instanceID int, collection string, snapshotAt time.Time, d time.Duration, status, note, stage string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	name, err := s.name(instanceID)
	if err != nil {
		return err
	}
	ob, err := s.bundle(name)
	if err != nil {
		return err
	}
	ob.b.AddRun(format.Run{Collection: collection, At: snapshotAt, Ms: d.Milliseconds(), Status: status, Note: note, Stage: stage})
	ob.count(collection, status)
	return nil
}

func (s *Store) failure(kind, name, engine, platform string, tags []string, collection string, at time.Time, d time.Duration, cause error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.ident[name]; !ok {
		s.ident[name] = format.Instance{Engine: engine, Name: name, Platform: platform, Tags: append([]string{}, tags...)}
	}
	ob, err := s.bundle(name)
	if err != nil {
		return err
	}
	why := ""
	if cause != nil {
		why = cause.Error()
	}
	ob.b.AddFailure(format.Failure{Kind: kind, Collection: collection, At: at, Ms: d.Milliseconds(), Cause: why})
	ob.count(collection, "error")
	return nil
}

// LogConnectFailure records a run that could not connect (the instance's bundle is opened with the identity given).
func (s *Store) LogConnectFailure(_ context.Context, name, engine, platform string, tags []string, collection string, at time.Time, d time.Duration, cause error) error {
	return s.failure("connect", name, engine, platform, tags, collection, at, d, cause)
}

// LogSecretFailure records a run whose secret could not be read.
func (s *Store) LogSecretFailure(_ context.Context, name, engine, platform string, tags []string, collection string, at time.Time, d time.Duration, cause error) error {
	return s.failure("secret", name, engine, platform, tags, collection, at, d, cause)
}

// LogRunFailure records a run that failed before its rows.
func (s *Store) LogRunFailure(_ context.Context, name, engine, collection string, at time.Time, d time.Duration, cause error) error {
	return s.failure("run", name, engine, "", nil, collection, at, d, cause)
}

// CloseInstance ends the instance's interval at end: schedule lists every collection of its schedule (Collection and
// IntervalSecs; Reason for one that did not run, else not_due), each read's status taken from its runs - ran when every
// run ended well, failed when one did not, skipped when none ran. An instance with nothing logged still gets its bundle
// (the empty interval). The bundle is closed and renamed, then its cursors committed; a failed close commits nothing.
func (s *Store) CloseInstance(name string, end time.Time, schedule []format.Read, hb format.Heartbeat) (format.Ref, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ob, err := s.bundle(name)
	if err != nil {
		return format.Ref{}, err
	}
	reads := make([]format.Read, 0, len(schedule))
	for _, r := range schedule {
		rd := format.Read{Collection: r.Collection, IntervalSecs: r.IntervalSecs}
		switch rc := ob.runs[r.Collection]; {
		case rc == nil:
			rd.Status, rd.Reason = format.ReadSkipped, r.Reason
			if rd.Reason == "" {
				rd.Reason = "not_due"
			}
		case rc.failed > 0:
			rd.Status, rd.Runs, rd.Failed = format.ReadFailed, rc.runs, rc.failed
		default:
			rd.Status, rd.Runs = format.ReadRan, rc.runs
		}
		reads = append(reads, rd)
	}
	cursors := make([]format.Cursor, 0, len(ob.moved))
	for _, c := range ob.moved {
		cursors = append(cursors, c)
	}
	sort.Slice(cursors, func(i, j int) bool { return cursors[i].Source < cursors[j].Source })
	delete(s.open, name)
	ref, err := ob.b.Close(end, reads, cursors, hb)
	if err != nil {
		return format.Ref{}, err
	}
	s.lastEnd[name] = ref.End
	if err := s.st.Commit(name, ob.seq, cursors); err != nil {
		return ref, fmt.Errorf("remote store: %s: the bundle is closed, its commit failed (Recover mends it at the next start): %w", name, err)
	}
	return ref, nil
}

// OpenInstances names the instances with an open bundle.
func (s *Store) OpenInstances() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, 0, len(s.open))
	for n := range s.open {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// lookup is a source's value as its reader asks it: refused when sources.go has no rule for it or names another reader;
// a hub setting is never on a remote site.
func (s *Store) lookup(instanceID int, source, reader string) (format.Cursor, bool, error) {
	r, ok := sourceRule(source)
	if !ok {
		return format.Cursor{}, false, fmt.Errorf("remote store: no rule for the cursor source %q (internal/remote/sources.go): a remote collector cannot answer it", source)
	}
	if r.Reader != reader {
		return format.Cursor{}, false, fmt.Errorf("remote store: the source %q is asked through the %s reader; sources.go names the %s reader", source, reader, r.Reader)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	name, err := s.name(instanceID)
	if err != nil {
		return format.Cursor{}, false, err
	}
	if r.Rule == "setting" {
		return format.Cursor{}, false, nil
	}
	if reader == "seq" && strings.HasPrefix(source, "qs_plan:") {
		c, ok := s.cursorLocked(name, "qs_plan_state:"+strings.TrimPrefix(source, "qs_plan:"))
		if !ok {
			return format.Cursor{}, false, nil
		}
		n, ok := qsPlanAnswer(c, s.o.Now())
		return format.Cursor{Source: source, Kind: "seq", Seq: n}, ok, nil
	}
	c, ok := s.cursorLocked(name, source)
	if !ok || c.Kind == "null" {
		return format.Cursor{}, false, nil
	}
	want := map[string]string{"log": "log", "mssql": "mssql", "seq": "seq"}[reader]
	if c.Kind != want {
		return format.Cursor{}, false, fmt.Errorf("remote store: the source %q holds a %s cursor, the %s reader asks it", source, c.Kind, reader)
	}
	return c, true, nil
}

// LogCursor answers how far a log source was read.
func (s *Store) LogCursor(_ context.Context, instanceID int, source string) (time.Time, bool, error) {
	c, ok, err := s.lookup(instanceID, source, "log")
	if err != nil || !ok || c.At == nil {
		return time.Time{}, false, err
	}
	return *c.At, true, nil
}

// MSSQLCursor answers how far a SQL Server file or event source was read.
func (s *Store) MSSQLCursor(_ context.Context, instanceID int, source string) (fileName string, fileOffset int64, lastEventAt time.Time, lastSeq int64, found bool, err error) {
	c, ok, err := s.lookup(instanceID, source, "mssql")
	if err != nil || !ok {
		return "", 0, time.Time{}, 0, false, err
	}
	if c.LastEventAt != nil {
		lastEventAt = *c.LastEventAt
	}
	return c.FileName, c.FileOffset, lastEventAt, c.LastSeq, true, nil
}

// MSSQLSeqCursor answers a SQL Server one-number cursor (mssql_hadr_cursor's sources).
func (s *Store) MSSQLSeqCursor(_ context.Context, instanceID int, source string) (int64, bool, error) {
	c, ok, err := s.lookup(instanceID, source, "seq")
	if err != nil || !ok {
		return 0, false, err
	}
	return c.Seq, true, nil
}
