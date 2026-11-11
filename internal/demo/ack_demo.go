package demo

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// SeedAcks writes a few rows of 0073's store on the demo fleet - a silenced instance, a mute rule, a known pattern, an
// acknowledged alert with a note - made by 'demo' (through import_ack, as the UI would).
func SeedAcks(ctx context.Context, pool *pgxpool.Pool) error {
	for _, sql := range []string{
		`DELETE FROM pgvigil.ack_suppressed WHERE ack_id IN (SELECT ack_id FROM pgvigil.acks WHERE created_by = 'demo')`,
		`DELETE FROM pgvigil.acks WHERE created_by = 'demo'`,
		`DELETE FROM pgvigil.ack_log WHERE ui_user = 'demo'`,
	} {
		if _, err := pool.Exec(ctx, sql); err != nil {
			return err
		}
	}
	_, err := pool.Exec(ctx, `
WITH a AS (SELECT finding_key, instance_name AS instance FROM pgvigil.alert_state WHERE cleared_at IS NULL ORDER BY first_sent_at, finding_key LIMIT 2)
SELECT pgvigil.import_ack($1, p) FROM (
  SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','silence','instance_name',(SELECT name FROM pgvigil.instances WHERE name LIKE 'demo-%' ORDER BY name DESC LIMIT 1),'note','patching this week') p
  UNION ALL SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','mute','check_key','idle_session_timeout','note','set on purpose for the pooler')
  UNION ALL SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','noise','match_text','jit','note','known: reporting jobs use JIT')
  UNION ALL SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','alert_ack','finding_key',finding_key,'instance_name',instance) FROM a
  UNION ALL SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','note','finding_key',finding_key,'instance_name',instance,'note','vendor ticket open') FROM a) q`, time.Now())
	return err
}
