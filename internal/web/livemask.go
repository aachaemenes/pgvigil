package web

import "github.com/aachaemenes/pgvigil/internal/cq"

// livemask.go (CQ-LIVEMASK): serve's DIRECT community run shows a tool's output as the request queue stores it, not
// as the server answered it. A community procedure's cell can carry a credential (a session's sqlcmd -P line read by
// pg_running, sp_WhoIsActive's batch text as a processing instruction <?query -- ... --?>); the queue masks every
// stored text (task 488), and the direct reply now takes the same mask, so one tool run shows the same text on either
// path. The audit row's detail and statement are masked before the write too, on both paths: the community page's run
// log ('Runs on this instance') shows them, so a row that kept a credential would be the same leak. The audit then
// records the masked words, not the server's own (docs/queue.md).

// maskRun masks a run in place: every text cell, every string inside a JSON cell at any depth (a json / jsonb column
// read by pgx), every column name and the run's error words, with the queue's own functions (cq.MaskRows,
// cq.MaskStrings, cq.MaskResult, cq.MaskText). communityExec calls it, so the queue's run passes through it too; the
// queue's later passes (cqSets, the worker's MaskResult) are idempotent. A JSON cell the mask cannot read is replaced
// by words, never shown as it came.
func maskRun(run *instanceRun) {
	for i := range run.Sets {
		cq.MaskStrings(run.Sets[i].Columns)
		cq.MaskRows(run.Sets[i].Rows)
		for _, r := range run.Sets[i].Rows {
			for j, c := range r {
				switch c.(type) {
				case map[string]any, []any:
					if m, err := cq.MaskResult(c); err == nil {
						r[j] = m
					} else {
						r[j] = "(not shown: the credential mask could not read this value)"
					}
				}
			}
		}
	}
	run.Error = cq.MaskText(run.Error)
}

// maskText is one text through the same mask (cq.MaskText): an error's words the direct path sends alone (the @help
// form's).
func maskText(s string) string { return cq.MaskText(s) }

// maskAudit masks an audit row's detail and statement in place before it is written (auditRun, cqAuditRow); no other
// field of the row is touched.
func maskAudit(row map[string]any) {
	for _, k := range []string{"detail", "statement"} {
		if s, ok := row[k].(string); ok && s != "" {
			row[k] = cq.MaskText(s)
		}
	}
}
