package mssql

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The three collections of the slice are registered under the engine's prefix with their cadences.
func TestStorageCollectorsRegistered(t *testing.T) {
	for name, want := range map[string]time.Duration{"mssql_storage": time.Hour, "mssql_versionstore": time.Minute} {
		c, ok := Get(name)
		if !ok {
			t.Fatalf("%s is not registered", name)
		}
		if c.DefaultInterval() != want {
			t.Errorf("%s: interval %v, want %v", name, c.DefaultInterval(), want)
		}
	}
	if runTimeout(storageCollector{}) != 5*time.Minute {
		t.Errorf("mssql_storage: the run's deadline is %v", runTimeout(storageCollector{}))
	}
}

func TestStorageApplies(t *testing.T) {
	full := Info{Kind: KindServer, Major: 16, ViewServerState: true, ViewAnyDefinition: true}
	for _, c := range []struct {
		name string
		col  Collector
		info Info
		ok   bool
		why  string
	}{
		{"storage, full rights", storageCollector{}, full, true, ""},
		{"storage, no VIEW SERVER STATE still runs (partial)", storageCollector{}, Info{Kind: KindServer, ViewAnyDefinition: true}, true, ""},
		{"storage, no VIEW ANY DEFINITION", storageCollector{}, Info{Kind: KindServer, ViewServerState: true}, false, "VIEW ANY DEFINITION"},
		{"storage, Azure SQL Database", storageCollector{}, Info{Kind: KindAzureDB, ViewServerState: true, ViewAnyDefinition: true}, false, "Azure SQL Database"},
		{"version store, full rights", versionStoreCollector{}, full, true, ""},
		{"version store, no VIEW SERVER STATE", versionStoreCollector{}, Info{Kind: KindServer, ViewAnyDefinition: true}, false, "VIEW SERVER STATE"},
		{"version store, Azure SQL Database", versionStoreCollector{}, Info{Kind: KindAzureDB, ViewServerState: true}, false, "Azure SQL Database"},
	} {
		ok, why := c.col.Applies(c.info)
		if ok != c.ok || !strings.Contains(why, c.why) {
			t.Errorf("%s: Applies = %v, %q; want %v with %q", c.name, ok, why, c.ok, c.why)
		}
	}
}

// The DMVs behind a version check: the per-database store from 2016 SP2, the persistent version store from 2019.
func TestVersionStoreVersionGates(t *testing.T) {
	for _, c := range []struct {
		major, build int
		byDB, pvs    bool
	}{
		{13, 4001, false, false}, // 2016 SP1: the floor
		{13, 5026, true, false},  // 2016 SP2
		{14, 1000, true, false},  // 2017
		{15, 2000, true, true},   // 2019
		{16, 4135, true, true},   // 2022
	} {
		in := Info{Major: c.major, Build: c.build}
		if mi := (Info{Kind: KindAzureMI, Major: 12, Build: 2000}); !hasStoreByDatabase(mi) || !hasPVS(mi) {
			t.Error("Managed Instance (product version 12.0) has both DMVs")
		}
		if hasStoreByDatabase(in) != c.byDB || hasPVS(in) != c.pvs {
			t.Errorf("%d.0.%d: by database %v, pvs %v; want %v, %v", c.major, c.build, hasStoreByDatabase(in), hasPVS(in), c.byDB, c.pvs)
		}
	}
}

func TestVolumeOf(t *testing.T) {
	for _, c := range []struct {
		mount, physical string
		read            bool
		want            string
	}{
		{`C:\`, `C:\Data\a.mdf`, true, `C:\`},
		{`E:\Mounts\Data1\`, `E:\Mounts\Data1\a.mdf`, true, `E:\Mounts\Data1\`},
		{"", "/var/opt/mssql/data/a.mdf", true, "/var/opt/mssql/data/"}, // Linux: no mount point named, the directory as it is
		{"", "/var/opt/mssql/data/a.mdf", false, ""},                    // the volume was not read (no right)
		{"", "https://account.blob.core.windows.net/c/a.mdf", false, ""},
		{"", "a.mdf", true, ""},
	} {
		if got := volumeOf(c.mount, c.physical, c.read); got != c.want {
			t.Errorf("volumeOf(%q, %q, %v) = %q; want %q", c.mount, c.physical, c.read, got, c.want)
		}
	}
}

// rawFiles is what filesSQL returns for two databases: one the login enters, one it cannot, on Linux.
func rawFiles() []collect.Row {
	f := func(db int64, name, state string, file int64, typ, phys string, size int64, enter int64) collect.Row {
		return collect.Row{"kind": "file", "database_id": db, "database_name": name, "database_state": state, "file_id": file,
			"file_name": name + "_f", "type_desc": typ, "physical_name": phys, "state_desc": "ONLINE", "size_bytes": size,
			"max_size_bytes": nil, "growth_bytes": int64(8 << 20), "growth_pct": int64(0), "can_enter": enter, "quoted_name": "[" + name + "]",
			"volume_mount_point": nil, "logical_volume_name": nil, "file_system_type": nil, "total_bytes": int64(1000), "available_bytes": int64(400)}
	}
	return []collect.Row{
		f(5, "open", "ONLINE", 1, "ROWS", "/data/open.mdf", 16<<20, 1),
		f(5, "open", "ONLINE", 2, "LOG", "/log/open.ldf", 8<<20, 1),
		f(5, "open", "ONLINE", 65537, "FILESTREAM", "/data/open_fs", 0, 1),
		f(6, "closed", "ONLINE", 1, "ROWS", "/data/closed.mdf", 4<<20, 0),
		f(7, "restoring", "RESTORING", 1, "ROWS", "/data/r.mdf", 4<<20, 0),
	}
}

func TestStorageRows(t *testing.T) {
	raw := rawFiles()
	files, vols := storageRows(raw)
	if len(files) != 5 || len(vols) != 2 {
		t.Fatalf("%d files, %d volumes; want 5, 2", len(files), len(vols))
	}
	if vols[0]["volume"] != "/data/" || vols[0]["files"] != 4 || vols[1]["volume"] != "/log/" || vols[1]["files"] != 1 {
		t.Errorf("volumes: %v", vols)
	}
	if vols[0]["total_bytes"] != int64(1000) || vols[0]["free_bytes"] != int64(400) {
		t.Errorf("the volume's sizes: %v", vols[0])
	}
	for _, f := range files {
		if f["used_read"] != 0 || f["used_bytes"] != nil {
			t.Errorf("before a database is read every file is 'used not read': %v", f)
		}
	}
	if n := files[3]["used_note"]; n != "used not read: the login cannot enter the database" {
		t.Errorf("the closed database's note: %v", n)
	}
	if n := files[4]["used_note"]; n != "used not read: the database is restoring" {
		t.Errorf("the restoring database's note: %v", n)
	}

	dbs := enterable(raw)
	if len(dbs) != 1 || dbs[0].id != 5 || dbs[0].quoted != "[open]" {
		t.Fatalf("enterable: %+v", dbs)
	}
	// the database's own read: the data file's current size differs (tempdb's case), the FILESTREAM container has no figure
	applyUsed(files, 5, []collect.Row{
		{"file_id": int64(1), "size_bytes": int64(32 << 20), "used_bytes": int64(3 << 20), "filegroup": "PRIMARY"},
		{"file_id": int64(2), "size_bytes": int64(8 << 20), "used_bytes": int64(1 << 20), "filegroup": nil},
		{"file_id": int64(65537), "size_bytes": int64(0), "used_bytes": nil, "filegroup": "FS"},
	})
	if files[0]["size_bytes"] != int64(32<<20) || files[0]["used_bytes"] != int64(3<<20) || files[0]["used_read"] != 1 ||
		files[0]["used_note"] != nil || files[0]["filegroup"] != "PRIMARY" {
		t.Errorf("the data file after the read: %v", files[0])
	}
	if files[1]["used_read"] != 1 || files[1]["filegroup"] != nil {
		t.Errorf("the log file after the read: %v", files[1])
	}
	if files[2]["used_read"] != 0 || !strings.Contains(files[2]["used_note"].(string), "no used space for this kind of file") {
		t.Errorf("the FILESTREAM container: %v", files[2])
	}
	if files[3]["used_read"] != 0 || files[3]["size_bytes"] != int64(4<<20) {
		t.Errorf("another database's file changed: %v", files[3])
	}
	noteUnread(files, 5, "the read of the database failed: lock request time out")
	if !strings.HasPrefix(files[0]["used_note"].(string), "used not read: the read of the database failed") {
		t.Errorf("noteUnread: %v", files[0]["used_note"])
	}
	if _, err := json.Marshal(append(files, vols...)); err != nil {
		t.Errorf("the payload does not marshal: %v", err)
	}
}

func TestFirstFew(t *testing.T) {
	if got := firstFew([]string{"a", "b"}, 5); got != "a, b" {
		t.Errorf("%q", got)
	}
	if got := firstFew([]string{"a", "b", "c"}, 2); got != "a, b and 1 more" {
		t.Errorf("%q", got)
	}
}

// The statements name what they read; none writes.
func TestStorageStatementsReadOnly(t *testing.T) {
	for name, q := range map[string]string{"filesSQL": filesSQL, "usedSQL": usedSQL, "storeSQL": storeSQL, "holderSQL": holderSQL,
		"storeDBSQL": storeDBSQL, "pvsSQL": pvsSQL, "sessionSQL": sessionSQL, "jobSQL": jobSQL, "actorSQL": actorSQL, "serverSQL2": serverSQL2} {
		u := " " + strings.ToUpper(q)
		for _, w := range []string{" INSERT ", " UPDATE ", " DELETE ", " MERGE ", " CREATE ", " ALTER ", " DROP ", " KILL ", " INTO "} {
			if strings.Contains(u, w) {
				t.Errorf("%s holds%s", name, w)
			}
		}
	}
}

// ---- the actions door ----

func TestDoorOff(t *testing.T) {
	on := Door{Monitor: "m", Actions: "a", Configured: true, Allow: []string{"kill", "job_start"}}
	for _, c := range []struct {
		name string
		d    Door
		k    ActionKind
		want string // "" = on
	}{
		{"on the list", on, ActionKill, ""},
		{"on the list too", on, ActionJobStart, ""},
		{"not on the list", on, ActionJobStop, "job_stop is not on the instance's actions: list"},
		{"an empty list is nothing", Door{Monitor: "m", Actions: "a", Configured: true}, ActionKill, "kill is not on the instance's actions: list"},
		{"no actions_dsn", Door{Monitor: "m", Allow: []string{"kill"}}, ActionKill, "has no actions_dsn"},
		{"an unresolved actions_dsn", Door{Monitor: "m", Configured: true, Allow: []string{"kill"}}, ActionKill, "resolved to an empty string"},
	} {
		got := c.d.Off("i1", c.k)
		if (c.want == "") != (got == "") || !strings.Contains(got, c.want) {
			t.Errorf("%s: Off = %q; want %q", c.name, got, c.want)
		}
	}
	for _, s := range []string{"kill", "job_start", "job_stop"} {
		if !ValidAction(s) {
			t.Errorf("ValidAction(%q) is false", s)
		}
	}
	for _, s := range []string{"", "terminate", "KILL", "job"} {
		if ValidAction(s) {
			t.Errorf("ValidAction(%q) is true", s)
		}
	}
}

func TestValidateAction(t *testing.T) {
	kill := ActionRequest{Instance: "i", Kind: ActionKill, SessionID: 77, LoginTime: "2026-11-10T07:00:00.123Z", Login: "app", Reason: "blocks the batch", User: "dba"}
	job := ActionRequest{Instance: "i", Kind: ActionJobStart, JobID: "6F9619FF-8B86-D011-B42D-00C04FC964FF", JobName: "nightly", Reason: "asked by the owner", User: "dba"}
	if err := ValidateAction(kill); err != nil {
		t.Errorf("a valid kill: %v", err)
	}
	if err := ValidateAction(job); err != nil {
		t.Errorf("a valid job start: %v", err)
	}
	bad := map[string]func(ActionRequest) ActionRequest{
		"session 0":        func(r ActionRequest) ActionRequest { r.SessionID = 0; return r },
		"negative session": func(r ActionRequest) ActionRequest { r.SessionID = -5; return r },
		"no login time":    func(r ActionRequest) ActionRequest { r.LoginTime = ""; return r },
		"bad login time":   func(r ActionRequest) ActionRequest { r.LoginTime = "yesterday"; return r },
		"no login":         func(r ActionRequest) ActionRequest { r.Login = " "; return r },
		"short reason":     func(r ActionRequest) ActionRequest { r.Reason = "x"; return r },
		"long reason":      func(r ActionRequest) ActionRequest { r.Reason = strings.Repeat("x", 501); return r },
		"NUL in reason":    func(r ActionRequest) ActionRequest { r.Reason = "blocks\x00 the batch"; return r },
		"no user":          func(r ActionRequest) ActionRequest { r.User = ""; return r },
		"unknown action":   func(r ActionRequest) ActionRequest { r.Kind = "terminate"; return r },
	}
	for name, f := range bad {
		if err := ValidateAction(f(kill)); err == nil {
			t.Errorf("kill, %s: accepted", name)
		}
	}
	for name, id := range map[string]string{"empty": "", "not a GUID": "nightly", "an injection": "6F9619FF-8B86-D011-B42D-00C04FC964FF'; DROP LOGIN x --",
		"braces": "{6F9619FF-8B86-D011-B42D-00C04FC964FF}"} {
		r := job
		r.JobID = id
		if err := ValidateAction(r); err == nil {
			t.Errorf("job id %s: accepted", name)
		}
	}
	r := job
	r.JobName = ""
	if err := ValidateAction(r); err == nil {
		t.Error("a job without the name shown: accepted")
	}
}

func TestStatement(t *testing.T) {
	if got := Statement(ActionKill, 77, ""); got != "KILL 77" {
		t.Errorf("%q", got)
	}
	if got := Statement(ActionJobStart, 0, "6f9619ff-8b86-d011-b42d-00c04fc964ff"); got != "EXEC msdb.dbo.sp_start_job @job_id = '6F9619FF-8B86-D011-B42D-00C04FC964FF'" {
		t.Errorf("%q", got)
	}
	if got := Statement(ActionJobStop, 0, "6F9619FF-8B86-D011-B42D-00C04FC964FF"); got != "EXEC msdb.dbo.sp_stop_job @job_id = '6F9619FF-8B86-D011-B42D-00C04FC964FF'" {
		t.Errorf("%q", got)
	}
}

// A session is never killed when it is a system session or pgvigil's own; a reused session id is not the session shown.
func TestSessionChecks(t *testing.T) {
	user := Target{SessionID: 77, Login: "app", LoginTime: "2026-11-10T07:00:00.123Z", userProcess: true, readerSPID: 60, readerLogin: "pgvigil_monitor"}
	if why := sessionRefusal(user); why != "" {
		t.Errorf("a user session: %q", why)
	}
	for name, c := range map[string]struct {
		f    func(Target) Target
		want string
	}{
		"not a user process":      {func(x Target) Target { x.userProcess = false; return x }, "system session"},
		"a low session id":        {func(x Target) Target { x.SessionID = 12; return x }, "system session"},
		"the check session":       {func(x Target) Target { x.SessionID = 60; return x }, "own check session"},
		"the read login":          {func(x Target) Target { x.Login = "PGVIGIL_MONITOR"; return x }, "own read login"},
		"the read login, exactly": {func(x Target) Target { x.Login = "pgvigil_monitor"; return x }, "own read login"},
	} {
		if why := sessionRefusal(c.f(user)); !strings.Contains(why, c.want) {
			t.Errorf("%s: %q; want %q", name, why, c.want)
		}
	}
	if !sameSession(user, "2026-11-10T07:00:00.123Z", "APP") {
		t.Error("the same session (a login's case differs) is refused")
	}
	if !sameSession(user, "2026-11-10T07:00:00.123000Z", "app") {
		t.Error("the same instant written with more digits is refused")
	}
	for name, c := range map[string][2]string{
		"a later login time": {"2026-11-10T07:00:00.127Z", "app"},
		"another login":      {"2026-11-10T07:00:00.123Z", "other"},
		"no login time":      {"", "app"},
	} {
		if sameSession(user, c[0], c[1]) {
			t.Errorf("%s: taken for the session shown", name)
		}
	}
}

func TestWithApp(t *testing.T) {
	for in, want := range map[string]string{
		"sqlserver://u@h:1433":                          "sqlserver://u@h:1433?app+name=pgvigil-actions",
		"sqlserver://u@h:1433?database=master":          "sqlserver://u@h:1433?database=master&app+name=pgvigil-actions",
		"sqlserver://u@h?app+name=mine":                 "sqlserver://u@h?app+name=mine",
		"server=h;user id=u;database=master":            "server=h;user id=u;database=master;app name=pgvigil-actions",
		"server=h;user id=u;app name=mine":              "server=h;user id=u;app name=mine",
		"odbc:server=h;user id=u":                       "odbc:server=h;user id=u",
		"server=h;user id=u;database=master; ":          "server=h;user id=u;database=master;app name=pgvigil-actions",
		"sqlserver://u@h:1433?database=happy+name+base": "sqlserver://u@h:1433?database=happy+name+base&app+name=pgvigil-actions",
	} {
		if got := withApp(in, "pgvigil-actions"); got != want {
			t.Errorf("withApp(%q) = %q; want %q", in, got, want)
		}
	}
}

// The audit row: a kill keeps the session id and the login time the check read; a job has no pid; a refusal before
// any read keeps what the request said; a NUL never reaches jsonb.
func TestActionRow(t *testing.T) {
	at := time.Date(2026, 11, 10, 8, 0, 0, 0, time.UTC)
	kill := ActionRequest{Instance: "i", Kind: ActionKill, SessionID: 77, LoginTime: "2026-11-10T07:00:00.123Z", Login: "app", Reason: " blocks the batch ", User: "dba", Client: "10.0.0.1"}
	res := ActionResult{Outcome: OutcomeDone, Detail: "KILL 77 sent", Statement: "KILL 77", ServerMessage: "ok",
		Target: Target{SessionID: 77, Login: "app", Host: "apphost", Program: "the app", LoginTime: "2026-11-10T07:00:00.123Z"}}
	row := ActionRow(at, kill, res)
	if row.PID == nil || *row.PID != 77 || row.BackendStart == nil || *row.BackendStart != "2026-11-10T07:00:00.123Z" ||
		row.TargetUser != "app" || row.TargetApp != "the app" || row.TargetHost != "apphost" || row.Reason != "blocks the batch" ||
		row.Statement != "KILL 77" || row.Action != "kill" || row.Outcome != "done" {
		t.Errorf("the kill's row: %+v", row)
	}
	early := ActionRow(at, kill, ActionResult{Outcome: OutcomeRefused, Detail: "kill is not on the list", Statement: "KILL 77"})
	if early.TargetUser != "app" || early.BackendStart == nil || early.Outcome != "refused" {
		t.Errorf("a refusal before the read: %+v", early)
	}
	job := ActionRequest{Instance: "i", Kind: ActionJobStop, JobID: "6F9619FF-8B86-D011-B42D-00C04FC964FF", JobName: "nightly", Reason: "", User: "d\x00ba"}
	jr := ActionRow(at, job, ActionResult{Outcome: OutcomeFailed, Detail: "refused\x00", Target: Target{JobName: "nightly", JobOwner: "sa"}})
	huge := kill
	huge.SessionID = 3000000000
	if hr := ActionRow(at, huge, ActionResult{Outcome: OutcomeRefused, Detail: "session_id must be a session id"}); hr.PID == nil || *hr.PID != 0 {
		t.Errorf("a number that is no session id must not reach the int column: %+v", hr.PID)
	}
	if jr.PID != nil || jr.BackendStart != nil || jr.Target != "nightly" || jr.TargetID != job.JobID || jr.TargetUser != "sa" ||
		jr.Reason != "(no reason given)" || jr.UIUser != "dba" || jr.Detail != "refused" {
		t.Errorf("the job's row: %+v", jr)
	}
	b, err := ActionPayload(row, jr)
	if err != nil || !strings.Contains(string(b), `"pid":null`) || !strings.Contains(string(b), `"pid":77`) {
		t.Errorf("the payload: %s (%v)", b, err)
	}
	long := kill
	long.Reason = strings.Repeat("r", 600)
	if got := ActionRow(at, long, res).Reason; len(got) != MaxActionReason {
		t.Errorf("a long reason is kept at %d characters, not %d", len(got), MaxActionReason)
	}
}

// Execute and Preview refuse before any connection when the door is off or the request is malformed.
func TestActionsRefuseWithoutConnecting(t *testing.T) {
	kill := ActionRequest{Instance: "i", Kind: ActionKill, SessionID: 77, LoginTime: "2026-11-10T07:00:00.123Z", Login: "app", Reason: "blocks the batch", User: "dba"}
	for name, c := range map[string]struct {
		d    Door
		r    ActionRequest
		want string
	}{
		"no actions_dsn":  {Door{Monitor: "sqlserver://nowhere.invalid"}, kill, "has no actions_dsn"},
		"not on the list": {Door{Monitor: "sqlserver://nowhere.invalid", Actions: "sqlserver://nowhere.invalid", Allow: []string{"job_start"}}, kill, "not on the instance's actions: list"},
		"malformed":       {Door{Monitor: "sqlserver://nowhere.invalid", Actions: "sqlserver://nowhere.invalid", Allow: []string{"kill"}}, ActionRequest{Kind: ActionKill}, "session_id"},
		"no read dsn":     {Door{Actions: "sqlserver://nowhere.invalid", Allow: []string{"kill"}}, kill, "read login's dsn resolved to an empty string"},
	} {
		res := Execute(t.Context(), c.d, c.r)
		if res.Outcome != OutcomeRefused || !strings.Contains(res.Detail, c.want) {
			t.Errorf("%s: %s, %q; want refused with %q", name, res.Outcome, res.Detail, c.want)
		}
	}
	if _, why := Preview(t.Context(), Door{Monitor: "m"}, "i", ActionKill, 77, ""); !strings.Contains(why, "has no actions_dsn") {
		t.Errorf("Preview with the door off: %q", why)
	}
	if _, why := Preview(t.Context(), Door{Monitor: "m", Actions: "a", Allow: []string{"job_stop"}}, "i", ActionJobStop, 0, "x'; --"); !strings.Contains(why, "GUID") {
		t.Errorf("Preview of a malformed job id: %q", why)
	}
}
