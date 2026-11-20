package collect

import "testing"

// B9c (B9-13): the statement each job action sends (or would have sent: a refusal's audit row carries it), per
// scheduler, and the actions login's name read from its dsn (the page offers a pg_cron job's Enable / Disable only
// for that login's own jobs).
func TestJobStatementAndLogin(t *testing.T) {
	for _, c := range []struct {
		kind, sch string
		pid       int
		want      string
	}{
		{JobEnable, "pgagent", 0, "UPDATE pgagent.pga_job SET jobenabled = true WHERE jobid = 7"},
		{JobDisable, "pgagent", 0, "UPDATE pgagent.pga_job SET jobenabled = false WHERE jobid = 7"},
		{JobEnable, "pg_cron", 0, "SELECT cron.alter_job(job_id := 7, active := true)"},
		{JobDisable, "pg_cron", 0, "SELECT cron.alter_job(job_id := 7, active := false)"},
		{JobStart, "pgagent", 0, "UPDATE pgagent.pga_job SET jobnextrun = now() WHERE jobid = 7"},
		{JobStop, "pg_cron", 4242, "SELECT pg_cancel_backend(4242)"},
		{JobStop, "pgagent", 0, ""},  // a pgAgent stop's pid is found by its checks
		{JobStart, "pg_cron", 0, ""}, // pg_cron has no run-now call
	} {
		if got := JobStatement(c.kind, c.sch, 7, c.pid); got != c.want {
			t.Errorf("JobStatement(%s, %s) = %q, want %q", c.kind, c.sch, got, c.want)
		}
	}
	for dsn, want := range map[string]string{
		"host=db user=pgvigil_actions dbname=postgres": "pgvigil_actions",
		"postgres://Actions_Login:pw@db:5432/postgres": "Actions_Login",
		"this is not a dsn = = '":                      "",
	} {
		if got := ActionsLoginName(dsn); got != want {
			t.Errorf("ActionsLoginName(%q) = %q, want %q", dsn, got, want)
		}
	}
}
