package dbadash

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"
)

func pageOf(page string, cols []string, rows ...[]any) PageReply {
	rs := ResultSet{Rows: rows}
	for _, c := range cols {
		rs.Columns = append(rs.Columns, Column{Name: c, Type: "NVARCHAR"})
	}
	return PageReply{Page: page, Results: []ResultSet{rs}}
}

// TestPageTextMasked: the text a page shows from a person or an application - a statement on the sessions page, a job's
// description, an alert's notification message - passes the credential mask the collection runs before the reply leaves
// the package; names and every other column are shown as DBA Dash holds them, and a page or a column not in the list is
// left byte for byte.
func TestPageTextMasked(t *testing.T) {
	tk := func(k int) string { return fmt.Sprintf("tk%d%x", k, time.Now().UnixNano()) }
	t1, t2, t3, t4 := tk(1), tk(2), tk(3), tk(4)
	batch := "CREATE LOGIN app WITH PASSWORD = '" + t1 + "'; SELECT 1"
	desc := "loads the warehouse; Server=db1;Database=app;User Id=etl;Password=" + t2 + ";"
	note := `page the DBA: sqlcmd -S db1 -U ops -P ` + t3 + ` -Q "EXEC dbo.ack"`
	name := "Password=" + t4 // a name holding a password shape: names are not masked

	sessions := pageOf("sessions", []string{"batch_text", "text", "login_name", "session_id"},
		[]any{batch, batch, name, int64(52)}, []any{nil, nil, "sa", int64(53)})
	maskPage(&sessions)
	row := sessions.Results[0].Rows[0]
	for i, w := range map[int]string{0: "CREATE LOGIN app WITH PASSWORD = '<masked>'; SELECT 1", 1: "CREATE LOGIN app WITH PASSWORD = '<masked>'; SELECT 1"} {
		if row[i] != w {
			t.Errorf("sessions %s: %q, want %q", sessions.Results[0].Columns[i].Name, row[i], w)
		}
	}
	if row[2] != name || row[3] != int64(52) {
		t.Errorf("sessions: a column not in the list changed: %v", row)
	}
	if r2 := sessions.Results[0].Rows[1]; r2[0] != nil || r2[1] != nil || r2[2] != "sa" {
		t.Errorf("sessions: a row without text changed: %v", r2)
	}

	// a statement shaped as an XML processing instruction (sp_WhoIsActive's <?query --...--?> form) is text, not a
	// document: the credential mask runs over it whole
	pi := pageOf("sessions", []string{"batch_text", "text"}, []any{"<?query --\nALTER LOGIN app WITH PASSWORD = '" + t1 + "'\n--?>", nil})
	maskPage(&pi)
	if got := pi.Results[0].Rows[0][0]; got != "<?query --\nALTER LOGIN app WITH PASSWORD = '<masked>'\n--?>" {
		t.Errorf("sessions, a statement in a processing instruction's shape: %q", got)
	}

	jobs := pageOf("jobs", []string{"name", "description"}, []any{"nightly", desc})
	maskPage(&jobs)
	if got := jobs.Results[0].Rows[0]; got[1] != "loads the warehouse; Server=db1;Database=app;User Id=etl;Password=<masked>;" || got[0] != "nightly" {
		t.Errorf("jobs: %v", got)
	}

	alerts := pageOf("alerts", []string{"Alert Name", "Notification Message"}, []any{"sev 17", note})
	maskPage(&alerts)
	if got := alerts.Results[0].Rows[0]; got[1] != `page the DBA: sqlcmd -S db1 -U ops -P <masked> -Q "EXEC dbo.ack"` || got[0] != "sev 17" {
		t.Errorf("alerts: %v", got)
	}

	for _, p := range []PageReply{
		pageOf("running", []string{"text", "Instance"}, []any{batch, "db1"}),             // a column of that name on a page that lists none
		pageOf("configuration", []string{"name", "value"}, []any{"x", "Password=" + t4}), // a page without text columns
	} {
		want := pageOf(p.Page, []string{p.Results[0].Columns[0].Name, p.Results[0].Columns[1].Name}, append([]any(nil), p.Results[0].Rows[0]...))
		maskPage(&p)
		if !reflect.DeepEqual(p, want) {
			t.Errorf("%s: changed: %v", p.Page, p.Results[0].Rows[0])
		}
	}
	for _, s := range []string{t1, t2, t3} {
		for _, p := range []PageReply{sessions, jobs, alerts} {
			if strings.Contains(fmt.Sprint(p.Results), s) {
				t.Errorf("%s: a credential is still shown", p.Page)
			}
		}
	}
}

// TestPageStatements: Statements gives the web each statement text of the reply (the sessions page's batch_text and
// text) for the instance's query_text: what f answers is shown; an empty cell, another column and another page's text
// are not given; a nil f changes nothing.
func TestPageStatements(t *testing.T) {
	var seen []string
	f := func(s string) any { seen = append(seen, s); return "X:" + s }
	sessions := pageOf("sessions", []string{"batch_text", "text", "login_name"}, []any{"SELECT 1", "SELECT 2", "sa"}, []any{nil, "", "app"})
	sessions.Statements(f)
	if got := sessions.Results[0].Rows[0]; got[0] != "X:SELECT 1" || got[1] != "X:SELECT 2" || got[2] != "sa" {
		t.Errorf("sessions: %v", got)
	}
	if got := sessions.Results[0].Rows[1]; got[0] != nil || got[1] != "" || got[2] != "app" {
		t.Errorf("sessions, an empty row: %v", got)
	}
	if len(seen) != 2 {
		t.Errorf("f saw %q, want the two statements", seen)
	}
	jobs := pageOf("jobs", []string{"name", "description"}, []any{"nightly", "SELECT 3"})
	jobs.Statements(f)
	if got := jobs.Results[0].Rows[0]; got[1] != "SELECT 3" {
		t.Errorf("jobs: a description is not a statement: %v", got)
	}
	none := pageOf("sessions", []string{"batch_text", "text"}, []any{"SELECT 1", "SELECT 1"})
	none.Statements(func(string) any { return nil })
	if got := none.Results[0].Rows[0]; got[0] != nil || got[1] != nil {
		t.Errorf("f answering nil: %v", got)
	}
	keep := pageOf("sessions", []string{"batch_text", "text"}, []any{"SELECT 1", "SELECT 1"})
	keep.Statements(nil)
	if got := keep.Results[0].Rows[0]; got[0] != "SELECT 1" || got[1] != "SELECT 1" {
		t.Errorf("a nil f: %v", got)
	}
}
