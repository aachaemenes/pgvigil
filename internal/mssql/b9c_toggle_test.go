package mssql

import (
	"strings"
	"testing"
	"time"
)

// B9c (B9-13): job_enable and job_disable on the SQL Server door - the kinds, the request's shape, the one statement
// (sp_update_job with @job_id and @enabled alone: what SQLAgentOperatorRole may send) and the audit row (no pid).
// Written against string kinds so it builds on the base and fails there.
func TestJobToggleKinds(t *testing.T) {
	for _, s := range []string{"job_enable", "job_disable"} {
		if !ValidAction(s) {
			t.Errorf("ValidAction(%q) is false", s)
		}
		found := false
		for _, k := range ActionKinds {
			found = found || string(k) == s
		}
		if !found {
			t.Errorf("ActionKinds %v lacks %s (the State route and the page list it)", ActionKinds, s)
		}
	}
	guid := "6f9619ff-8b86-d011-b42d-00c04fc964ff"
	for k, want := range map[string]string{
		"job_enable":  "EXEC msdb.dbo.sp_update_job @job_id = '6F9619FF-8B86-D011-B42D-00C04FC964FF', @enabled = 1",
		"job_disable": "EXEC msdb.dbo.sp_update_job @job_id = '6F9619FF-8B86-D011-B42D-00C04FC964FF', @enabled = 0",
	} {
		if got := Statement(ActionKind(k), 0, guid); got != want {
			t.Errorf("Statement(%s) = %q, want %q", k, got, want)
		}
		ok := ActionRequest{Instance: "i", Kind: ActionKind(k), JobID: guid, JobName: "nightly", Reason: "asked by the owner", User: "dba"}
		if err := ValidateAction(ok); err != nil {
			t.Errorf("ValidateAction(%s): %v", k, err)
		}
		for name, bad := range map[string]ActionRequest{
			"no GUID": {Instance: "i", Kind: ActionKind(k), JobID: "nightly'; DROP", JobName: "nightly", Reason: "asked by the owner", User: "dba"},
			"no name": {Instance: "i", Kind: ActionKind(k), JobID: guid, JobName: " ", Reason: "asked by the owner", User: "dba"},
		} {
			if err := ValidateAction(bad); err == nil {
				t.Errorf("ValidateAction(%s, %s) passed", k, name)
			}
		}
		d := Door{Monitor: "m", Actions: "a", Configured: true, Allow: []string{"job_start", "job_stop"}}
		if off := d.Off("i", ActionKind(k)); !strings.Contains(off, k+" is not on the instance's actions: list") {
			t.Errorf("Off(%s) on a list without it = %q", k, off)
		}
		row := ActionRow(time.Unix(0, 0), ok, ActionResult{Outcome: OutcomeRefused, Detail: "x", Statement: Statement(ActionKind(k), 0, guid)})
		if row.PID != nil || row.Target != "nightly" || row.TargetID != guid || row.Action != k {
			t.Errorf("ActionRow(%s) = pid %v, target %q, id %q, action %q", k, row.PID, row.Target, row.TargetID, row.Action)
		}
	}
}
