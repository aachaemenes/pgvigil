package web

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// fakeDoorStore is the repository as the door's scope rule reads it: instances, the open alerts' keys and the stored
// rows an end, an edit, a pause or a resume names.
type fakeDoorStore struct {
	inst    map[int]doorInstance
	finding map[string]int
	rows    map[doorRowRef]doorRow
	fail    string // the lookup that cannot be read: its name, "" = none
}

var errStoreDown = errors.New("the store did not answer")

func (f fakeDoorStore) instance(_ context.Context, id int) (doorInstance, bool, error) {
	if f.fail == "instance" {
		return doorInstance{}, false, errStoreDown
	}
	i, ok := f.inst[id]
	return i, ok, nil
}

func (f fakeDoorStore) instanceByName(_ context.Context, name string) (int, bool, error) {
	if f.fail == "instanceByName" {
		return 0, false, errStoreDown
	}
	for id, i := range f.inst {
		if i.Name == name {
			return id, true, nil
		}
	}
	return 0, false, nil
}

func (f fakeDoorStore) findingInstance(_ context.Context, key string) (int, bool, error) {
	if f.fail == "findingInstance" {
		return 0, false, errStoreDown
	}
	id, ok := f.finding[key]
	return id, ok, nil
}

func (f fakeDoorStore) row(_ context.Context, ref doorRowRef) (doorRow, bool, error) {
	if f.fail == "row" {
		return doorRow{}, false, errStoreDown
	}
	r, ok := f.rows[ref]
	return r, ok, nil
}

func (f fakeDoorStore) demoInstances(_ context.Context, ids []int, prefix string) ([]int, error) {
	if f.fail == "demoInstances" {
		return nil, errStoreDown
	}
	out := []int{}
	for _, id := range ids {
		if i, ok := f.inst[id]; ok && i.DemoTag && strings.HasPrefix(i.Name, prefix) {
			out = append(out, id)
		}
	}
	return out, nil
}

func intp(i int) *int { return &i }

// TestDemoDoorScope is the door's scope rule as a table (task B7): a write goes through the demo's door only when
// every instance it touches was seeded by this process AND still carries the tag 'demo' AND still has the demo's name
// prefix; a write wider than one instance, a route the door does not carry, an alert key that does not belong to the
// instance named and a stored row without an instance are refused, each in words.
func TestDemoDoorScope(t *testing.T) {
	store := fakeDoorStore{
		inst: map[int]doorInstance{
			1: {Name: "demo-pg01", DemoTag: true},  // seeded by this process
			2: {Name: "demo-pg02", DemoTag: true},  // seeded by this process
			3: {Name: "prod-db1", DemoTag: false},  // a real instance beside the demo's
			4: {Name: "prod-db2", DemoTag: true},   // a real instance someone tagged 'demo': never seeded here
			5: {Name: "demo-pg05", DemoTag: false}, // seeded here, then claimed by a real collector (the tag rewritten)
			6: {Name: "erp-main", DemoTag: true},   // seeded here, its name no longer the demo's
			7: {Name: "demo-pg07", DemoTag: true},  // a demo name and tag from an older run, not in this process's list
		},
		finding: map[string]int{"k-demo1": 1, "k-demo2": 2, "k-prod": 3, "k-repo": 0},
		rows: map[doorRowRef]doorRow{
			{"acks", 10}:             {InstanceID: intp(1), InstanceName: "demo-pg01"},
			{"acks", 11}:             {InstanceID: intp(3), InstanceName: "prod-db1"},
			{"acks", 12}:             {},                                                 // a rule by tag or text: every instance
			{"acks", 13}:             {InstanceName: "demo-pg02", FindingKey: "k-demo2"}, // the seed's shape: a name and a key, no id
			{"acks", 14}:             {InstanceName: "gone-server"},                      // its instance was removed
			{"acks", 15}:             {InstanceID: intp(1), FindingKey: "k-prod"},        // a demo id on a real instance's alert
			{"acks", 16}:             {InstanceID: intp(1), FindingKey: "k-cleared"},     // its alert is no longer in alert_state
			{"acks", 17}:             {InstanceID: intp(1), FindingKey: "k-repo"},        // a demo id on an alert of no instance
			{"acks", 18}:             {Tag: "demo"},                                      // a rule by tag (the seed's own mute): every instance that carries the tag
			{"alert_dismissals", 20}: {FindingKey: "k-demo1"},
			{"alert_dismissals", 21}: {FindingKey: "k-prod"},
			{"job_exclusions", 30}:   {InstanceID: intp(2)},
			{"job_exclusions", 31}:   {},                    // a root-level exclusion
			{"job_exclusions", 32}:   {InstanceID: intp(3)}, // a real instance's exclusion
		},
	}
	d := &demoDoor{ids: map[int]bool{1: true, 2: true, 5: true, 6: true}, prefix: "demo-", look: store}
	const notDemo, wide = "is not one of this demo's instances", "would reach past the demo's instances"
	const noInstance, noLevel, oneInstance = "names no instance that exists", "is not a level the demo writes at", "level names one instance: instance_id is missing or not a number"
	for _, c := range []struct {
		name string
		sc   writeScope
		want string // "" = allowed; else words the refusal must hold
	}{
		{"an acknowledgement on a seeded instance", writeScope{Route: doorAck, InstanceID: 1}, ""},
		{"a real instance beside the demo's", writeScope{Route: doorAck, InstanceID: 3}, "prod-db1 " + notDemo},
		{"a real instance tagged demo by hand", writeScope{Route: doorAck, InstanceID: 4}, "prod-db2 " + notDemo},
		{"a seeded id whose tag a collector rewrote", writeScope{Route: doorAck, InstanceID: 5}, "demo-pg05 " + notDemo},
		{"a seeded id whose name is no longer the demo's", writeScope{Route: doorAck, InstanceID: 6}, "erp-main " + notDemo},
		{"a demo name and tag this process did not seed", writeScope{Route: doorAck, InstanceID: 7}, "demo-pg07 " + notDemo},
		{"an instance that does not exist", writeScope{Route: doorAck, InstanceID: 99}, "no instance 99"},
		{"an alert of a seeded instance by its key", writeScope{Route: doorAck, FindingKey: "k-demo1"}, ""},
		{"the key and the instance agree", writeScope{Route: doorAck, InstanceID: 1, FindingKey: "k-demo1"}, ""},
		{"a real instance's alert key with a demo instance id", writeScope{Route: doorAck, InstanceID: 1, FindingKey: "k-prod"}, "belongs to another instance"},
		{"a real instance's alert key alone", writeScope{Route: doorDismiss, FindingKey: "k-prod"}, "prod-db1 " + notDemo},
		{"an alert of no instance (repository-wide, or its instance removed)", writeScope{Route: doorAck, FindingKey: "k-repo"}, noInstance},
		{"a key no alert holds", writeScope{Route: doorDismiss, FindingKey: "k-nothing"}, "no alert has this key"},
		{"a rule that names no instance and no alert", writeScope{Route: doorAck}, "an every-instance change " + wide},
		{"a silence that names no instance (a name alone is not read)", writeScope{Route: doorAck, OneInstance: true}, "names one instance or one alert"},
		{"a silence of a seeded instance", writeScope{Route: doorAck, OneInstance: true, InstanceID: 1}, ""},
		{"a rule by tag", writeScope{Route: doorAck, Tag: "env:prod"}, "a tag 'env:prod' change " + wide},
		{"a rule by tag on one seeded instance", writeScope{Route: doorAck, Tag: "env:prod", InstanceID: 2}, ""},
		{"a root threshold", writeScope{Route: doorDriveThreshold, Level: "root"}, "a root change " + wide},
		{"a tag threshold", writeScope{Route: doorPgThreshold, Level: "tag", Tag: "demo"}, "a tag 'demo' change " + wide},
		{"a root threshold that also names a seeded instance", writeScope{Route: doorPgThreshold, Level: "root", InstanceID: 1}, "a root change " + wide},
		{"an instance threshold", writeScope{Route: doorDriveThreshold, Level: "instance", InstanceID: 1}, ""},
		{"a drive threshold", writeScope{Route: doorDriveThreshold, Level: "drive", InstanceID: 2}, ""},
		{"a database threshold on a real instance", writeScope{Route: doorPgThreshold, Level: "database", InstanceID: 3}, "prod-db1 " + notDemo},
		{"a threshold level that names no instance", writeScope{Route: doorPgThreshold, Level: "database"}, "a database " + oneInstance},
		{"a level of another route (a database level on a drive threshold)", writeScope{Route: doorDriveThreshold, Level: "database", InstanceID: 1}, "'database' " + noLevel},
		{"a level in another case", writeScope{Route: doorDriveThreshold, Level: "Root", InstanceID: 1}, "'Root' " + noLevel},
		{"a level no function knows", writeScope{Route: doorPgThreshold, Level: "fleet", InstanceID: 1}, "'fleet' " + noLevel},
		{"a threshold without a level", writeScope{Route: doorDriveThreshold, InstanceID: 1}, "'' " + noLevel},
		{"a database threshold on a seeded instance", writeScope{Route: doorPgThreshold, Level: "database", InstanceID: 2}, ""},
		// a job's thresholds and the job exclusions are the door's again with their pages (B7 DONE-3): one instance or below
		{"a job's threshold on a seeded instance", writeScope{Route: doorJobThreshold, Level: "job", InstanceID: 1}, ""},
		{"an instance's job threshold on a seeded instance", writeScope{Route: doorJobThreshold, Level: "instance", InstanceID: 1}, ""},
		{"a job's threshold on a real instance", writeScope{Route: doorJobThreshold, Level: "job", InstanceID: 3}, "prod-db1 " + notDemo},
		{"a root job threshold", writeScope{Route: doorJobThreshold, Level: "root"}, "a root change " + wide},
		{"a job threshold level that names no instance", writeScope{Route: doorJobThreshold, Level: "job"}, "a job " + oneInstance},
		{"a level of another route (a drive level on a job threshold)", writeScope{Route: doorJobThreshold, Level: "drive", InstanceID: 1}, "'drive' " + noLevel},
		{"a job level on an exclusion (root or instance only)", writeScope{Route: doorJobExclusion, Level: "job", InstanceID: 1}, "'job' " + noLevel},
		{"a root job exclusion", writeScope{Route: doorJobExclusion, Level: "root"}, "a root change " + wide},
		{"an instance's job exclusion on a seeded instance", writeScope{Route: doorJobExclusion, Level: "instance", InstanceID: 2}, ""},
		{"the end of a seeded instance's row", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 10}}, ""},
		{"the end of a real user's row on a real instance", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 11}}, "prod-db1 " + notDemo},
		{"the end of a rule on every instance", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 12}}, "an every-instance change " + wide},
		{"the end of a rule by tag (its words name the tag)", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 18}}, "a tag 'demo' change " + wide},
		{"the end of a seed row (a name and a key, no id)", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 13}}, ""},
		{"the end of a row whose instance was removed", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 14}}, "gone-server is no longer an instance"},
		{"the end of a row with a demo id on a real alert", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 15}}, "prod-db1 " + notDemo},
		{"the end of a row whose alert is gone", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 16}}, ""},
		{"the end of a row that does not exist", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 404}}, "no such row 404"},
		{"the end of a row with a demo id on an alert of no instance", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 17}}, noInstance},
		{"an undismiss of a seeded instance's alert", writeScope{Route: doorDismiss, Row: &doorRowRef{"alert_dismissals", 20}}, ""},
		{"an undismiss of a real instance's alert", writeScope{Route: doorDismiss, Row: &doorRowRef{"alert_dismissals", 21}}, "prod-db1 " + notDemo},
		{"the end of a seeded instance's exclusion", writeScope{Route: doorJobExclusion, Row: &doorRowRef{"job_exclusions", 30}}, ""},
		{"the end of a root exclusion", writeScope{Route: doorJobExclusion, Row: &doorRowRef{"job_exclusions", 31}}, "an every-instance change " + wide},
		{"the end of a real instance's exclusion", writeScope{Route: doorJobExclusion, Row: &doorRowRef{"job_exclusions", 32}}, "prod-db1 " + notDemo},
		{"a pause of a seeded instance's mute", writeScope{Route: doorMuteChange, Row: &doorRowRef{"acks", 10}}, ""},
		{"an edit that asks for every instance", writeScope{Route: doorMuteChange, Row: &doorRowRef{"acks", 10}, AnyInstance: true}, "an every-instance change " + wide},
		{"an edit that moves the rule to a real instance", writeScope{Route: doorMuteChange, Row: &doorRowRef{"acks", 10}, InstanceID: 3}, "prod-db1 " + notDemo},
		{"an edit that moves a rule on every instance to a seeded instance (it would end the wide rule)", writeScope{Route: doorMuteChange, Row: &doorRowRef{"acks", 12}, InstanceID: 1}, "an every-instance change " + wide},
		{"an edit of a real instance's rule", writeScope{Route: doorMuteChange, Row: &doorRowRef{"acks", 11}, InstanceID: 1}, "prod-db1 " + notDemo},
		{"Send test", writeScope{Route: doorAlertTest}, "pgvigil demo -serve runs no sender"},
		{"a route the door was never taught", writeScope{Route: "customreports", InstanceID: 1}, "is not made through the demo"},
		{"no route at all", writeScope{InstanceID: 1}, "is not made through the demo"},
	} {
		got, err := d.allow(context.Background(), c.sc)
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		if (c.want == "") != (got == "") || !strings.Contains(got, c.want) {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// TestSeatOnServe pins what a serve answers at a write's door, the demo's door absent: the header first, then the
// route's own off reason word for word, and no pool without them (a serve is unchanged by the demo's door, -no-login
// included).
func TestSeatOnServe(t *testing.T) {
	s := &Server{} // no login, no demo door: pgvigil serve -no-login
	const noLogin = "acknowledgements need the UI login: this server runs with -no-login"
	if got := s.ackOff(); got != noLogin {
		t.Fatalf("ackOff on a serve without the login = %q, want %q", got, noLogin)
	}
	if got := s.offWords(s.ackOff(), "thresholds"); got != "thresholds need the UI login: this server runs with -no-login" {
		t.Errorf("a page's off words on a serve without the login = %q (the serve's words, the page's noun)", got)
	}
	for _, c := range []struct {
		name   string
		header bool
		code   int
		words  string
	}{
		{"no header", false, http.StatusForbidden, "the X-Pgvigil header is required"},
		{"the header, no login", true, http.StatusForbidden, noLogin},
	} {
		r := httptest.NewRequest(http.MethodPost, "/api/ack", strings.NewReader("{}"))
		if c.header {
			r.Header.Set(loginHeader, "1")
		}
		w := httptest.NewRecorder()
		if _, ok := s.seat(w, r, s.ackOff()); ok {
			t.Errorf("%s: a seat was given", c.name)
		}
		if w.Code != c.code || !strings.Contains(w.Body.String(), c.words) {
			t.Errorf("%s: %d %s, want %d with %q", c.name, w.Code, strings.TrimSpace(w.Body.String()), c.code, c.words)
		}
	}
}

// TestSeatOnDemo: on a demo serve the header is still the first check, the seat is the door's own user, and the pool
// comes only with a scope the door allows.
func TestSeatOnDemo(t *testing.T) {
	store := fakeDoorStore{inst: map[int]doorInstance{1: {Name: "demo-pg01", DemoTag: true}, 3: {Name: "prod-db1"}}}
	s := &Server{demo: &demoDoor{ids: map[int]bool{1: true}, prefix: "demo-", look: store}}
	if got := s.ackOff(); !strings.Contains(got, "pgvigil demo -serve") || strings.Contains(got, "-no-login") {
		t.Errorf("ackOff on a demo serve = %q: it names pgvigil demo -serve and never -no-login", got)
	}
	// a page's words on a demo serve are the door's, under the page's noun (its controls are taught the door, B7 DONE-3)
	if got := s.offWords(s.ackOff(), "job exclusions"); !strings.Contains(got, "pgvigil demo -serve: job exclusions are saved as user demo") || strings.Contains(got, "-no-login") {
		t.Errorf("a page's off words on a demo serve = %q", got)
	}
	r := httptest.NewRequest(http.MethodPost, "/api/ack", strings.NewReader("{}"))
	w := httptest.NewRecorder()
	if _, ok := s.seat(w, r, s.ackOff()); ok || w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), "the X-Pgvigil header is required") {
		t.Errorf("no header on a demo serve: ok %v, %d %s", ok, w.Code, strings.TrimSpace(w.Body.String()))
	}
	r.Header.Set(loginHeader, "1")
	w = httptest.NewRecorder()
	seat, ok := s.seat(w, r, s.ackOff())
	if !ok || seat.user != "demo" || seat.client != "demo door" {
		t.Fatalf("the demo's seat: ok %v, user %q, client %q (want demo, demo door)", ok, seat.user, seat.client)
	}
	if _, why, err := seat.pool(context.Background(), writeScope{Route: doorAck, InstanceID: 3}); err != nil || !strings.Contains(why, "prod-db1 is not one of this demo's instances") {
		t.Errorf("a real instance through the demo's seat: why %q, err %v", why, err)
	}
	if _, why, err := seat.pool(context.Background(), writeScope{Route: doorAck, InstanceID: 1}); err != nil || why != "" {
		t.Errorf("a seeded instance through the demo's seat: why %q, err %v", why, err)
	}
	// the door's pool is its own: with an actions door standing beside it (two pools never opened, told apart by their
	// address) an allowed write gets the door's and a refused one gets none - never the audit login's
	audit, door := new(pgxpool.Pool), new(pgxpool.Pool)
	s.actions, s.demo.pool = &Actions{audit: audit}, door
	if p, why, err := seat.pool(context.Background(), writeScope{Route: doorAck, InstanceID: 1}); p != door || why != "" || err != nil {
		t.Errorf("an allowed write's pool: the door's own %v (the audit login's %v), why %q, err %v", p == door, p == audit, why, err)
	}
	if p, _, _ := seat.pool(context.Background(), writeScope{Route: doorAck, InstanceID: 3}); p != nil {
		t.Errorf("a refused write got a pool (the audit login's: %v)", p == audit)
	}
	if _, why, _ := seat.pool(context.Background(), writeScope{}); why == "" {
		t.Error("a write that names no route and no scope got the demo's pool")
	}
}

// TestDoorScopeReaders: a handler's payload read into a scope as its import_ function will read it - the level names
// the scope, an instance_id counts only in the shape the function accepts, an end goes by its row, and alertDoor's
// list gives a route only to the functions it names.
func TestDoorScopeReaders(t *testing.T) {
	row := func(sc writeScope) doorRowRef {
		if sc.Row == nil {
			return doorRowRef{}
		}
		return *sc.Row
	}
	for _, c := range []struct {
		name string
		got  writeScope
		want writeScope
		row  doorRowRef
	}{
		{"a root level", scopeOfLevel(doorDriveThreshold, map[string]any{"level": "root", "instance_id": "7"}), writeScope{Route: doorDriveThreshold, Level: "root", InstanceID: 7}, doorRowRef{}},
		{"a tag level", scopeOfLevel(doorPgThreshold, map[string]any{"level": "tag", "tag": "env:prod"}), writeScope{Route: doorPgThreshold, Level: "tag", Tag: "env:prod"}, doorRowRef{}},
		{"an instance id as a JSON number", scopeOfLevel(doorJobThreshold, map[string]any{"level": "instance", "instance_id": float64(7)}), writeScope{Route: doorJobThreshold, Level: "instance", InstanceID: 7}, doorRowRef{}},
		{"an instance id as text", scopeOfLevel(doorDriveThreshold, map[string]any{"level": "drive", "instance_id": "12"}), writeScope{Route: doorDriveThreshold, Level: "drive", InstanceID: 12}, doorRowRef{}},
		{"an instance id the function would not read", scopeOfLevel(doorDriveThreshold, map[string]any{"level": "instance", "instance_id": "7.5"}), writeScope{Route: doorDriveThreshold, Level: "instance"}, doorRowRef{}},
		{"an instance id of ten digits", scopeOfLevel(doorDriveThreshold, map[string]any{"level": "instance", "instance_id": "1234567890"}), writeScope{Route: doorDriveThreshold, Level: "instance"}, doorRowRef{}},
		{"an exclusion's add", scopeOfExclusion(map[string]any{"op": "add", "level": "instance", "instance_id": float64(2), "exclusion_id": float64(31)}), writeScope{Route: doorJobExclusion, Level: "instance", InstanceID: 2}, doorRowRef{}},
		{"an exclusion's end", scopeOfExclusion(map[string]any{"op": "end", "exclusion_id": float64(31), "level": "instance", "instance_id": float64(2)}), writeScope{Route: doorJobExclusion}, doorRowRef{"job_exclusions", 31}},
		{"Send test", scopeOfAlertFn("import_alert_test", map[string]any{"channel": "ops"}), writeScope{Route: doorAlertTest}, doorRowRef{}},
		{"a dismiss", scopeOfAlertFn("import_alert_dismiss", map[string]any{"op": "add", "finding_key": "abc"}), writeScope{Route: doorDismiss, FindingKey: "abc"}, doorRowRef{}},
		{"an undismiss", scopeOfAlertFn("import_alert_dismiss", map[string]any{"op": "end", "dismiss_id": int64(20)}), writeScope{Route: doorDismiss}, doorRowRef{"alert_dismissals", 20}},
		{"a pause", scopeOfAlertFn("import_ack_change", map[string]any{"op": "pause", "ack_id": int64(10)}), writeScope{Route: doorMuteChange}, doorRowRef{"acks", 10}},
		{"an edit to every instance", scopeOfAlertFn("import_ack_change", map[string]any{"op": "edit", "ack_id": int64(10), "any_instance": true}), writeScope{Route: doorMuteChange, AnyInstance: true}, doorRowRef{"acks", 10}},
		{"an edit to another instance", scopeOfAlertFn("import_ack_change", map[string]any{"op": "edit", "ack_id": int64(10), "instance_id": 3, "tag": "x"}), writeScope{Route: doorMuteChange, InstanceID: 3, Tag: "x"}, doorRowRef{"acks", 10}},
		{"a function alertDoor's list does not name", scopeOfAlertFn("import_alert_channels", map[string]any{"instance_id": 1}), writeScope{}, doorRowRef{}},
	} {
		g := c.got
		gr := row(g)
		g.Row = nil
		if g != c.want || gr != c.row {
			t.Errorf("%s: got %+v row %+v, want %+v row %+v", c.name, g, gr, c.want, c.row)
		}
	}
}

// TestDoorStoreError: a scope that cannot be read is never an allowed write - each of the door's lookups failing gives
// an error and no pool, and the handler's poolFor answers 500 'nothing was written'.
func TestDoorStoreError(t *testing.T) {
	base := fakeDoorStore{
		inst:    map[int]doorInstance{1: {Name: "demo-pg01", DemoTag: true}},
		finding: map[string]int{"k-demo1": 1},
		rows:    map[doorRowRef]doorRow{{"acks", 10}: {InstanceID: intp(1)}, {"acks", 13}: {InstanceName: "demo-pg01", FindingKey: "k-demo1"}},
	}
	for _, c := range []struct {
		fail string
		sc   writeScope // a scope the door allows when the store answers, and that reads the failing lookup
	}{
		{"instance", writeScope{Route: doorAck, InstanceID: 1}},
		{"findingInstance", writeScope{Route: doorAck, FindingKey: "k-demo1"}},
		{"row", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 10}}},
		{"instanceByName", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 13}}},
		{"findingInstance", writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", 13}}},
	} {
		up := &demoDoor{ids: map[int]bool{1: true}, prefix: "demo-", look: base, pool: new(pgxpool.Pool)}
		if why, err := up.allow(context.Background(), c.sc); why != "" || err != nil {
			t.Errorf("%s: the scope is refused while the store answers (%q, %v): the row proves nothing", c.fail, why, err)
			continue
		}
		down := base
		down.fail = c.fail
		s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil)), demo: &demoDoor{ids: map[int]bool{1: true}, prefix: "demo-", look: down, pool: new(pgxpool.Pool)}}
		if why, err := s.demo.allow(context.Background(), c.sc); err == nil {
			t.Errorf("%s down: allow answered %q without an error", c.fail, why)
		}
		seat := writeSeat{s: s, user: doorUser, client: doorClient}
		if p, why, err := seat.pool(context.Background(), c.sc); p != nil || why != "" || !errors.Is(err, errStoreDown) {
			t.Errorf("%s down: a pool %v, why %q, err %v (want no pool and the store's error)", c.fail, p != nil, why, err)
		}
		w := httptest.NewRecorder()
		if p, ok := seat.poolFor(context.Background(), w, c.sc); ok || p != nil || w.Code != http.StatusInternalServerError || !strings.Contains(w.Body.String(), "nothing was written") {
			t.Errorf("%s down: poolFor ok %v, %d %s (want 500 'nothing was written')", c.fail, ok, w.Code, strings.TrimSpace(w.Body.String()))
		}
	}
}

// TestDoorInfo: the page is told only the instances the door would write for now - seeded here AND still tagged demo
// AND still under the demo's prefix; a store that does not answer names none (every control off, in words).
func TestDoorInfo(t *testing.T) {
	store := fakeDoorStore{inst: map[int]doorInstance{
		1: {Name: "demo-pg01", DemoTag: true}, 2: {Name: "demo-pg02", DemoTag: true},
		5: {Name: "demo-pg05", DemoTag: false}, // claimed by a real collector since
		6: {Name: "erp-main", DemoTag: true},   // renamed since
		7: {Name: "demo-pg07", DemoTag: true},  // never seeded by this process
	}}
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil)), demo: &demoDoor{ids: map[int]bool{1: true, 2: true, 5: true, 6: true}, prefix: "demo-", look: store}}
	if got := s.doorInfo(context.Background()); got["user"] != "demo" || !reflect.DeepEqual(got["instances"], []int{1, 2}) {
		t.Errorf("the door as the page is told: %v (want user demo, instances [1 2])", got)
	}
	store.fail = "demoInstances"
	s.demo.look = store
	if got := s.doorInfo(context.Background()); !reflect.DeepEqual(got["instances"], []int{}) {
		t.Errorf("the store down: the page is told %v (want no instance)", got["instances"])
	}
	if got := (&Server{}).doorInfo(context.Background()); got != nil {
		t.Errorf("a serve is told of a door: %v", got)
	}
}

// TestDoorMustConnect: the door's own pool is tried when the door opens. A login that cannot connect (a role at its
// connection limit, a server gone) is an error at Open - never a demo that starts with Acknowledge on and every click
// answering 500 (pgxpool makes its pool without a connect).
func TestDoorMustConnect(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	d, err := newDemoDoor(ctx, &Server{}, &DemoDoor{DSN: "host=127.0.0.1 port=1 user=nobody dbname=nothing connect_timeout=1 sslmode=disable", Instances: []int{1}, Prefix: "demo-"})
	if err == nil {
		d.close()
		t.Fatal("a door whose login cannot connect was opened")
	}
	if !strings.Contains(err.Error(), "demo door") {
		t.Errorf("the error does not say whose it is: %v", err)
	}
}
