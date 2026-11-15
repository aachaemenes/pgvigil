package collect

import (
	"strings"
	"testing"
)

// B9c (B9-13): job_enable and job_disable on the PostgreSQL job door - both schedulers (pgAgent's jobenabled, pg_cron's
// cron.alter_job active), no run named, the rest of the request's rules as Run now's. String kinds: it builds on the
// base and fails there.
func TestJobToggleRequest(t *testing.T) {
	for _, k := range []string{"job_enable", "job_disable"} {
		for _, sch := range []string{"pgagent", "pg_cron"} {
			ok := JobActionRequest{Kind: k, Scheduler: sch, JobID: 7, JobName: "nightly", Reason: "asked by the owner", User: "dba"}
			if err := ValidateJobAction(ok); err != nil {
				t.Errorf("ValidateJobAction(%s, %s): %v", k, sch, err)
			}
		}
		for name, bad := range map[string]JobActionRequest{
			"no job":       {Kind: k, Scheduler: "pg_cron", JobName: "nightly", Reason: "asked by the owner", User: "dba"},
			"no name":      {Kind: k, Scheduler: "pg_cron", JobID: 7, JobName: " ", Reason: "asked by the owner", User: "dba"},
			"no scheduler": {Kind: k, JobID: 7, JobName: "nightly", Reason: "asked by the owner", User: "dba"},
			"short reason": {Kind: k, Scheduler: "pgagent", JobID: 7, JobName: "nightly", Reason: "x", User: "dba"},
			"no user":      {Kind: k, Scheduler: "pgagent", JobID: 7, JobName: "nightly", Reason: "asked by the owner"},
		} {
			if err := ValidateJobAction(bad); err == nil {
				t.Errorf("ValidateJobAction(%s, %s) passed", k, name)
			}
		}
	}
	if err := ValidateJobAction(JobActionRequest{Kind: "job_drop", Scheduler: "pg_cron", JobID: 7, JobName: "n", Reason: "asked by the owner", User: "dba"}); err == nil || !strings.Contains(err.Error(), "unknown job action") {
		t.Errorf("an unknown kind: %v", err)
	}
}
