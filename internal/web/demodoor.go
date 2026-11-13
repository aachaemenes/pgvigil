package web

// The demo's write door (task B7). `pgvigil demo -serve` serves an invented fleet on loopback without the UI login,
// so every write of the UI was refused there and its buttons were off. With Options.DemoDoor set - only the demo
// command sets it - the writes that touch ONLY pgvigil's own repository work on the demo's own instances as the
// built-in user 'demo':
//
//	who      'demo' in ui_user (the acknowledge log, created_by, ended_by: as any user), client 'demo door'
//	where    an instance this process seeded that still carries the tag 'demo' and the demo's name prefix; never
//	         another instance of the same repository, whatever its tags say
//	what     an acknowledgement, a note, a close, a silence, a blackout, a mute or a known pattern of ONE instance or
//	         ONE alert, a dismiss, and a threshold or a job exclusion at the instance level or below
//	never    a write wider than one instance (a root or tag level, a rule on every instance), a level its route does
//	         not write at, Send test, and every route this file does not name - each refused in words
//
// One path: the door calls the same import_ functions with the same payloads as a serve does, on a small pool of its
// own on the demo's repository login. A handler asks seat() who writes, then asks that seat for the pool with the
// write's scope: on a demo serve there is no pool without a scope the door allows. A serve is unchanged: its seat is
// the session's user and its pool the actions door's audit login, as before. The door's pool is never the audit pool.

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// DemoDoor opens the demo's write door (Options.DemoDoor): the demo's own repository login, the instances this
// process seeded and the name prefix it seeded them with.
type DemoDoor struct {
	DSN       string
	Instances []int
	Prefix    string
}

const (
	doorUser   = "demo"
	doorClient = "demo door"
	// doorOff is what the UI is told where it asks whether writes are possible: on a demo serve 'writable' stays
	// false with these words, and the door's instances are named beside them
	doorOff = "this is pgvigil demo -serve: acknowledgements are saved as user demo, on the demo's own instances only; a change wider than one instance, or one that reaches a server, needs pgvigil serve with a signed-in user"
	// doorNoInstance: an alert whose alert_state row names no instance - a repository-wide alert, or one whose instance
	// was removed (the delete nulls its id)
	doorNoInstance = "this alert names no instance that exists (a repository-wide alert, or one whose instance was removed): it is not changed through the demo"
)

// doorRoute names a write route for the door's allow-list.
type doorRoute string

const (
	doorAck            doorRoute = "ack"
	doorAckEnd         doorRoute = "ack/end"
	doorDismiss        doorRoute = "alerts/dismiss"
	doorMuteChange     doorRoute = "alerts/mute"
	doorAlertTest      doorRoute = "alerts/test"
	doorDriveThreshold doorRoute = "drives/thresholds"
	doorPgThreshold    doorRoute = "pg/thresholds"
	doorJobThreshold   doorRoute = "jobs/thresholds"
	doorJobExclusion   doorRoute = "jobs/exclusions"
)

// doorRowRef names a stored row an end, an edit, a pause or a resume acts on: acks (ack_id), alert_dismissals
// (dismiss_id) or job_exclusions (exclusion_id).
type doorRowRef struct {
	Table string
	ID    int64
}

// writeScope is what one write touches, as its handler read it from the request.
type writeScope struct {
	Route       doorRoute
	Level       string      // a threshold's or an exclusion's level: 'root' and 'tag' are wider than one instance
	Tag         string      // the tag of a tag level or of a rule
	InstanceID  int         // the instance the request names; 0 = none
	FindingKey  string      // an alert's key: its instance comes from alert_state, never from the request
	Row         *doorRowRef // the stored row the request acts on
	AnyInstance bool        // an edit that asks for every instance
}

type doorInstance struct {
	Name    string
	DemoTag bool
}

// doorRow is a stored row's own scope.
type doorRow struct {
	InstanceID   *int
	InstanceName string
	FindingKey   string
}

// doorLookup is the repository as the scope rule reads it.
type doorLookup interface {
	instance(ctx context.Context, id int) (doorInstance, bool, error)
	instanceByName(ctx context.Context, name string) (int, bool, error)
	// findingInstance: the instance of an alert by its key; (0, true) = an alert of no instance (repository-wide, or
	// its instance was removed)
	findingInstance(ctx context.Context, key string) (int, bool, error)
	row(ctx context.Context, ref doorRowRef) (doorRow, bool, error)
	// demoInstances: of ids, those that still carry the tag 'demo' and a name under prefix, in ascending order
	demoInstances(ctx context.Context, ids []int, prefix string) ([]int, error)
}

type demoDoor struct {
	pool   *pgxpool.Pool
	ids    map[int]bool
	prefix string
	look   doorLookup
}

// doorLevels: the levels a threshold or an exclusion is written at through the door, by route - one instance or
// below it, from each function's own list (0111, 0117, 0094, 0102) without its root and tag. A level this list does
// not name for its route is refused: another case, a level of another route, none.
var doorLevels = map[doorRoute][]string{
	doorDriveThreshold: {"instance", "drive"},
	doorPgThreshold:    {"instance", "database"},
	doorJobThreshold:   {"instance", "job"},
	doorJobExclusion:   {"instance"},
}

func doorWide(what string) string {
	return what + " change would reach past the demo's instances: set it on one demo instance here, or use pgvigil serve with a signed-in user"
}

// allow says why the door refuses a write, "" when it carries it.
func (d *demoDoor) allow(ctx context.Context, sc writeScope) (string, error) {
	switch sc.Route {
	case doorAck, doorAckEnd, doorDismiss, doorMuteChange, doorDriveThreshold, doorPgThreshold, doorJobThreshold, doorJobExclusion:
	case doorAlertTest:
		return "Send test asks the alert sender to send a message; pgvigil demo -serve runs no sender and sends nothing here", nil
	default:
		return "this change is not made through the demo: it needs pgvigil serve with a signed-in user", nil
	}
	if sc.AnyInstance {
		return doorWide("an every-instance"), nil
	}
	switch sc.Level {
	case "root":
		return doorWide("a root"), nil
	case "tag":
		return doorWide("a tag '" + sc.Tag + "'"), nil
	}
	// a threshold or an exclusion written by its level (an exclusion's end goes by its row): the level is one of the
	// route's own, and such a level names an instance
	if levels, byLevel := doorLevels[sc.Route]; byLevel && sc.Row == nil {
		known := false
		for _, l := range levels {
			known = known || l == sc.Level
		}
		if !known {
			return fmt.Sprintf("'%s' is not a level the demo writes at (%s): nothing was written", sc.Level, strings.Join(levels, ", ")), nil
		}
		if sc.InstanceID <= 0 {
			return "a " + sc.Level + " level names one instance: instance_id is missing or not a number, nothing was written", nil
		}
	}
	want := map[int]bool{}
	if sc.InstanceID > 0 {
		want[sc.InstanceID] = true
	}
	if sc.FindingKey != "" {
		id, ok, err := d.look.findingInstance(ctx, sc.FindingKey)
		switch {
		case err != nil:
			return "", err
		case !ok:
			return "no alert has this key: nothing was written", nil
		case id == 0:
			return doorNoInstance, nil
		case sc.InstanceID > 0 && id != sc.InstanceID:
			return "the alert belongs to another instance than the one named: nothing was written", nil
		}
		want[id] = true
	}
	if sc.Row != nil {
		r, ok, err := d.look.row(ctx, *sc.Row)
		if err != nil {
			return "", err
		}
		if !ok {
			return fmt.Sprintf("no such row %d: nothing was written", sc.Row.ID), nil
		}
		why, err := d.rowInstances(ctx, r, want)
		if err != nil || why != "" {
			return why, err
		}
	}
	if len(want) == 0 {
		if sc.Tag != "" {
			return doorWide("a tag '" + sc.Tag + "'"), nil
		}
		return doorWide("an every-instance"), nil
	}
	ids := make([]int, 0, len(want))
	for id := range want {
		ids = append(ids, id)
	}
	sort.Ints(ids)
	for _, id := range ids {
		in, ok, err := d.look.instance(ctx, id)
		if err != nil {
			return "", err
		}
		if !ok {
			return fmt.Sprintf("no instance %d", id), nil
		}
		if !d.ids[id] || !in.DemoTag || !strings.HasPrefix(in.Name, d.prefix) {
			return in.Name + " is not one of this demo's instances: changing it needs pgvigil serve with a signed-in user", nil
		}
	}
	return "", nil
}

// rowInstances adds a stored row's instances to want: its instance_id, the instance its name still names, the
// instance of its alert. A row that names none of them applies to every instance (a rule by check, tag or text) and
// is refused; so is a row whose instance was removed (its name kept, its id gone).
func (d *demoDoor) rowInstances(ctx context.Context, r doorRow, want map[int]bool) (string, error) {
	n := 0
	if r.InstanceID != nil {
		want[*r.InstanceID] = true
		n++
	} else if r.InstanceName != "" {
		id, ok, err := d.look.instanceByName(ctx, r.InstanceName)
		if err != nil {
			return "", err
		}
		if !ok {
			return r.InstanceName + " is no longer an instance: its row is not changed through the demo", nil
		}
		want[id] = true
		n++
	}
	if r.FindingKey != "" {
		id, ok, err := d.look.findingInstance(ctx, r.FindingKey)
		switch {
		case err != nil:
			return "", err
		case ok && id == 0:
			return doorNoInstance, nil
		case ok:
			want[id] = true
			n++
		case n == 0:
			// the alert left alert_state and the row names no instance: nothing says whose it was
			return "no alert has this key: nothing was written", nil
		}
	}
	if n == 0 {
		return doorWide("an every-instance"), nil
	}
	return "", nil
}

// payText is a payload value as the text its import_ function reads with ->>.
func payText(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case bool:
		return strconv.FormatBool(x)
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case int:
		return strconv.Itoa(x)
	case int64:
		return strconv.FormatInt(x, 10)
	}
	return fmt.Sprint(v)
}

var (
	payInstanceRE = regexp.MustCompile(`^[0-9]{1,9}$`)  // as the functions read an instance_id
	payRowRE      = regexp.MustCompile(`^[0-9]{1,18}$`) // as they read a row's id
)

// payInstance is a payload's instance id as its function will read it; 0 = none.
func payInstance(v any) int {
	t := payText(v)
	if !payInstanceRE.MatchString(t) {
		return 0
	}
	n, _ := strconv.Atoi(t)
	return n
}

func payRow(v any) int64 {
	t := payText(v)
	if !payRowRE.MatchString(t) {
		return 0
	}
	n, _ := strconv.ParseInt(t, 10, 64)
	return n
}

// scopeOfLevel reads a threshold write's scope from the payload its function is given: the functions bind the scope
// by 'level' alone - root and tag name no instance, every other level needs one (0111, 0117, 0094, 0102).
func scopeOfLevel(route doorRoute, pay map[string]any) writeScope {
	return writeScope{Route: route, Level: payText(pay["level"]), Tag: payText(pay["tag"]), InstanceID: payInstance(pay["instance_id"])}
}

// scopeOfExclusion: a job exclusion's end goes by its row, an add by its level.
func scopeOfExclusion(pay map[string]any) writeScope {
	if payText(pay["op"]) == "end" {
		return writeScope{Route: doorJobExclusion, Row: &doorRowRef{"job_exclusions", payRow(pay["exclusion_id"])}}
	}
	return scopeOfLevel(doorJobExclusion, pay)
}

// scopeOfAlertFn is alertDoor's route list: the scope of a write by the import_ function it calls. A function this
// list does not name has no route, and the door refuses it.
func scopeOfAlertFn(fn string, pay map[string]any) writeScope {
	switch fn {
	case "import_alert_test":
		return writeScope{Route: doorAlertTest}
	case "import_alert_dismiss":
		if payText(pay["op"]) == "end" {
			return writeScope{Route: doorDismiss, Row: &doorRowRef{"alert_dismissals", payRow(pay["dismiss_id"])}}
		}
		return writeScope{Route: doorDismiss, FindingKey: payText(pay["finding_key"])}
	case "import_ack_change":
		anyInstance, _ := pay["any_instance"].(bool)
		return writeScope{Route: doorMuteChange, Row: &doorRowRef{"acks", payRow(pay["ack_id"])}, AnyInstance: anyInstance,
			InstanceID: payInstance(pay["instance_id"]), Tag: payText(pay["tag"])}
	}
	return writeScope{}
}

// newDemoDoor connects the door's own pool. The lookups read through the UI's read-only pool.
func newDemoDoor(ctx context.Context, s *Server, o *DemoDoor) (*demoDoor, error) {
	if strings.TrimSpace(o.Prefix) == "" {
		return nil, errors.New("demo door: the demo's name prefix is empty")
	}
	pc, err := pgxpool.ParseConfig(o.DSN)
	if err != nil {
		return nil, fmt.Errorf("demo door dsn: %w", err)
	}
	pc.ConnConfig.ConnectTimeout = 10 * time.Second
	rp := pc.ConnConfig.RuntimeParams
	rp["application_name"] = "pgvigil-demo-door"
	rp["statement_timeout"] = "5000"
	rp["lock_timeout"] = "2000"
	pc.MaxConns = 2
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, fmt.Errorf("demo door: %w", err)
	}
	d := &demoDoor{pool: pool, ids: map[int]bool{}, prefix: o.Prefix, look: pgDoorLookup{s.pool}}
	for _, id := range o.Instances {
		d.ids[id] = true
	}
	return d, nil
}

func (d *demoDoor) close() {
	if d != nil && d.pool != nil {
		d.pool.Close()
	}
}

// doorInfo is what the UI is told of the door: its user and the instances it would write for now - seeded by this
// process AND still tagged demo AND still under the demo's prefix, the rule of allow, so a control is never on for an
// instance the door would refuse. A store that does not answer names none. nil on a serve.
func (s *Server) doorInfo(ctx context.Context) map[string]any {
	if s.demo == nil {
		return nil
	}
	ids := make([]int, 0, len(s.demo.ids))
	for id := range s.demo.ids {
		ids = append(ids, id)
	}
	sort.Ints(ids)
	live, err := s.demo.look.demoInstances(ctx, ids, s.demo.prefix)
	if err != nil {
		s.log.Error("demo door: its instances were not read", "err", err)
		live = nil
	}
	if live == nil {
		live = []int{}
	}
	return map[string]any{"user": doorUser, "instances": live}
}

// writeSeat is who writes for one request.
type writeSeat struct {
	s      *Server
	user   string
	client string
}

// seat runs a write's first checks in their order and says who writes: the X-Pgvigil header (a page of another site
// cannot set it, and a scripted request with it needs a preflight this server never grants); then on a serve the
// route's own off reason and the session's user, as before; on a demo serve the door's own user. false = the refusal
// is written.
func (s *Server) seat(w http.ResponseWriter, r *http.Request, off string) (writeSeat, bool) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return writeSeat{}, false
	}
	if s.demo != nil {
		return writeSeat{s: s, user: doorUser, client: doorClient}, true
	}
	if off != "" {
		writeErr(w, http.StatusForbidden, errors.New(off))
		return writeSeat{}, false
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return writeSeat{}, false
	}
	return writeSeat{s: s, user: user, client: clientIP(r)}, true
}

// pool is the pool the write runs on, and on a demo serve the door's refusal in words: there is no pool without a
// scope the door allows.
func (ws writeSeat) pool(ctx context.Context, sc writeScope) (*pgxpool.Pool, string, error) {
	if ws.s.demo == nil {
		return ws.s.actions.audit, "", nil
	}
	why, err := ws.s.demo.allow(ctx, sc)
	if err != nil || why != "" {
		return nil, why, err
	}
	return ws.s.demo.pool, "", nil
}

// poolFor is pool with the refusal written: 403 in the door's words, 500 when the scope could not be read.
func (ws writeSeat) poolFor(ctx context.Context, w http.ResponseWriter, sc writeScope) (*pgxpool.Pool, bool) {
	p, why, err := ws.pool(ctx, sc)
	switch {
	case err != nil:
		ws.s.log.Error("demo door: the write's scope was not read", "route", string(sc.Route), "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("the write's scope was not read: nothing was written (%v)", err))
		return nil, false
	case why != "":
		writeErr(w, http.StatusForbidden, errors.New(why))
		return nil, false
	}
	return p, true
}

// pgDoorLookup reads the scope rule's facts through the UI's read-only pool.
type pgDoorLookup struct{ pool *pgxpool.Pool }

func (l pgDoorLookup) instance(ctx context.Context, id int) (doorInstance, bool, error) {
	var in doorInstance
	err := l.pool.QueryRow(ctx, `SELECT name, 'demo' = ANY (tags) FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&in.Name, &in.DemoTag)
	if errors.Is(err, pgx.ErrNoRows) {
		return in, false, nil
	}
	return in, err == nil, err
}

func (l pgDoorLookup) instanceByName(ctx context.Context, name string) (int, bool, error) {
	var id int
	err := l.pool.QueryRow(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name = $1`, name).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	return id, err == nil, err
}

func (l pgDoorLookup) findingInstance(ctx context.Context, key string) (int, bool, error) {
	var id *int
	err := l.pool.QueryRow(ctx, `SELECT instance_id FROM pgvigil.alert_state WHERE finding_key = $1 ORDER BY last_sent_at DESC LIMIT 1`, key).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	if id == nil {
		return 0, true, nil
	}
	return *id, true, nil
}

func (l pgDoorLookup) demoInstances(ctx context.Context, ids []int, prefix string) ([]int, error) {
	rows, err := l.pool.Query(ctx, `SELECT instance_id FROM pgvigil.instances
 WHERE instance_id = ANY ($1::int[]) AND 'demo' = ANY (tags) AND starts_with(name, $2) ORDER BY instance_id`, ids, prefix)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[int])
}

func (l pgDoorLookup) row(ctx context.Context, ref doorRowRef) (doorRow, bool, error) {
	var q string
	switch ref.Table {
	case "acks":
		q = `SELECT instance_id, coalesce(instance_name, ''), coalesce(finding_key, '') FROM pgvigil.acks WHERE ack_id = $1`
	case "alert_dismissals":
		q = `SELECT instance_id, coalesce(instance_name, ''), finding_key FROM pgvigil.alert_dismissals WHERE dismiss_id = $1`
	case "job_exclusions":
		q = `SELECT instance_id, '', '' FROM pgvigil.job_exclusions WHERE exclusion_id = $1`
	default:
		return doorRow{}, false, nil
	}
	var r doorRow
	err := l.pool.QueryRow(ctx, q, ref.ID).Scan(&r.InstanceID, &r.InstanceName, &r.FindingKey)
	if errors.Is(err, pgx.ErrNoRows) {
		return r, false, nil
	}
	return r, err == nil, err
}
