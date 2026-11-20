package web

import (
	"encoding/json"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

// TestConfigExpectPayload: the editor's attempt reaches import_mssql_config_expect with the fields the function
// reads and no other, the signed-in user and its client set by the server (never taken from the body), the instance
// as its digits (the door and the function read the same text) and a list value as a list.
func TestConfigExpectPayload(t *testing.T) {
	var in map[string]any
	body := `{"op":"set","level":"instance","instance_id":7,"kind":"xe","key":"running","value":["system_health","x"],
	  "exclusions":["master"],"ui_user":"mallory","client":"elsewhere","created_by":"mallory","extra":1,"tag":null}`
	if err := json.Unmarshal([]byte(body), &in); err != nil {
		t.Fatal(err)
	}
	pay := configExpectPayload(in, "alice", "10.0.0.9")
	want := map[string]any{"op": "set", "level": "instance", "instance_id": "7", "kind": "xe", "key": "running",
		"value": []any{"system_health", "x"}, "exclusions": []any{"master"}, "ui_user": "alice", "client": "10.0.0.9"}
	if !reflect.DeepEqual(pay, want) {
		t.Errorf("payload %v, want %v", pay, want)
	}
	// the door reads the level and the instance from the same payload
	if sc := scopeOfLevel(doorConfigExpect, pay); sc.Route != doorConfigExpect || sc.Level != "instance" || sc.InstanceID != 7 {
		t.Errorf("the write's scope: %+v", sc)
	}
	// a number value stays a number, a root level names no instance (a map of its own: Unmarshal into the first one
	// would keep that body's instance)
	var root map[string]any
	if err := json.Unmarshal([]byte(`{"op":"set","level":"root","kind":"instance","key":"errorlog_files","value":10}`), &root); err != nil {
		t.Fatal(err)
	}
	pay = configExpectPayload(root, "alice", "")
	if pay["value"] != float64(10) || pay["instance_id"] != nil {
		t.Errorf("a root number: %v", pay)
	}
	if lv := doorLevels[doorConfigExpect]; len(lv) != 1 || lv[0] != "instance" {
		t.Errorf("the demo door carries an expected value at one instance only: %v", lv)
	}
}

// TestConfigCheckQueries: the reads name 0160's objects, take the instance as their first parameter and write nothing.
func TestConfigCheckQueries(t *testing.T) {
	for name, q := range map[string]string{"checks": sqlConfigChecks, "parts": sqlConfigCheckParts, "facts": sqlConfigCheckFacts, "xe": sqlConfigCheckXE,
		"databases": sqlConfigCheckDatabases, "linked": sqlConfigCheckLinked, "runs": sqlConfigCheckRuns, "in_force": sqlConfigExpectInForce,
		"keys": sqlConfigExpectKeys, "tags": sqlConfigExpectTags} {
		u := strings.ToUpper(q)
		if !strings.HasPrefix(strings.TrimSpace(u), "SELECT") {
			t.Errorf("%s is not a SELECT", name)
		}
		for _, bad := range []string{"INSERT ", "UPDATE ", "DELETE ", "IMPORT_"} {
			if strings.Contains(u, bad) {
				t.Errorf("%s holds %q", name, bad)
			}
		}
	}
	if !strings.Contains(sqlConfigChecks, "pgvigil.mssql_config_checks_of($1)") || !strings.Contains(sqlConfigExpectInForce, "pgvigil.mssql_config_expect_in_force($1)") {
		t.Error("the grid and the values in force are read through 0160's functions for one instance")
	}
	// no remote login's name is ever read for the page
	if strings.Contains(strings.ToLower(sqlConfigCheckLinked), "remote_name") {
		t.Error("the linked servers' read names a remote login")
	}
}

// TestOptionalInstance: the expected values' GET reads its instance when one is given (the values in force are one
// instance's), takes 0 without it, and refuses anything that is not a positive instance_id.
func TestOptionalInstance(t *testing.T) {
	for q, want := range map[string]int{"": 0, "?instance=7": 7, "?part=in_force&instance=12": 12} {
		if id, err := optionalInstance(httptest.NewRequest("GET", "/api/mssql/config_expect"+q, nil)); err != nil || id != want {
			t.Errorf("%q: %d %v, want %d", q, id, err, want)
		}
	}
	for _, q := range []string{"?instance=abc", "?instance=0", "?instance=-3", "?instance=1.5"} {
		if id, err := optionalInstance(httptest.NewRequest("GET", "/api/mssql/config_expect"+q, nil)); err == nil || id != 0 {
			t.Errorf("%q: %d %v, want an error", q, id, err)
		}
	}
}
