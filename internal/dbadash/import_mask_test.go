package dbadash

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// TestImportBatchMasked: an imported job run's message passes the masks a collected one does (collect.ApplyTextPolicy,
// whose credential mask runs under every query_text mode); the names and the numbers stay as DBA Dash holds them, a
// message with no credential is kept byte for byte, and an empty mode is full.
func TestImportBatchMasked(t *testing.T) {
	for i, mode := range []string{"", "full", "normalized", "none"} {
		tok := func(k int) string { return fmt.Sprintf("tk%d%d%x", i, k, time.Now().UnixNano()) }
		t1, t2, t3 := tok(1), tok(2), tok(3)
		msg := `Executed as user: NT SERVICE\SQLAgent. sqlcmd -S db1 -U agent -P ` + t1 + ` -Q "EXEC dbo.load" then ` +
			`Server=db1;Database=app;User Id=agent;Password=` + t2 + `; then $p = ConvertTo-SecureString '` + t3 +
			`' -AsPlainText -Force. The step succeeded.`
		plain := `Executed as user: NT SERVICE\SQLAgent. The step succeeded.`
		batch := []map[string]any{
			{"at": "2026-11-15T10:00:00Z", "history_id": int64(7), "job_name": "nightly load", "step_name": "load", "step_id": int64(1), "message": msg},
			{"at": "2026-11-15T10:00:01Z", "history_id": int64(8), "job_name": "nightly load", "step_name": "load", "step_id": int64(2), "message": plain},
		}
		maskBatch(batch, mode)
		got, _ := batch[0]["message"].(string)
		for _, s := range []string{t1, t2, t3} {
			if strings.Contains(got, s) {
				t.Errorf("mode %q: a credential is still in the message: %q", mode, got)
			}
		}
		for _, w := range []string{"-P <masked> -Q", "Password=<masked>;", "ConvertTo-SecureString <masked>", "Database=app", "The step succeeded."} {
			if !strings.Contains(got, w) {
				t.Errorf("mode %q: the message %q has no %q", mode, got, w)
			}
		}
		if batch[0]["job_name"] != "nightly load" || batch[0]["step_name"] != "load" || batch[0]["history_id"] != int64(7) || batch[0]["step_id"] != int64(1) {
			t.Errorf("mode %q: the row's other columns changed: %v", mode, batch[0])
		}
		if batch[1]["message"] != plain {
			t.Errorf("mode %q: a message with no credential changed: %q", mode, batch[1]["message"])
		}
	}
}
