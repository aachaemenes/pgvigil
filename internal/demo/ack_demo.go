package demo

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// SeedAcks writes a few rows of 0073's store on the demo fleet - a silenced instance, a mute rule, a known pattern, an
// acknowledged alert with a note - made by 'demo' (through import_ack, as the UI would). Every row is the demo fleet's
// only: the alerts and the silenced instance are instances tagged demo whose name starts with prefix, the two rules carry
// tag 'demo', and a re-seed deletes only rows whose client is 'demo seed' (a real user named demo keeps theirs).
func SeedAcks(ctx context.Context, pool *pgxpool.Pool, prefix string) error {
	for _, sql := range []string{
		`DELETE FROM pgvigil.ack_suppressed WHERE ack_id IN (SELECT ack_id FROM pgvigil.acks WHERE client = 'demo seed')`,
		`DELETE FROM pgvigil.acks WHERE client = 'demo seed'`,
		`DELETE FROM pgvigil.ack_log WHERE client = 'demo seed'`,
	} {
		if _, err := pool.Exec(ctx, sql); err != nil {
			return err
		}
	}
	_, err := pool.Exec(ctx, `
WITH d AS (SELECT name FROM pgvigil.instances WHERE 'demo' = ANY (tags) AND starts_with(name, $2)),
a AS (SELECT s.finding_key, s.instance_name AS instance FROM pgvigil.alert_state s JOIN d ON d.name = s.instance_name
       WHERE s.cleared_at IS NULL ORDER BY s.first_sent_at, s.finding_key LIMIT 2),
si AS (SELECT name FROM d ORDER BY name DESC LIMIT 1)
SELECT pgvigil.import_ack($1, p) FROM (
  SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','silence','instance_name',si.name,'note','patching this week') p FROM si
  UNION ALL SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','mute','check_key','idle_session_timeout','tag','demo','note','set on purpose for the pooler')
  UNION ALL SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','noise','match_text','jit','tag','demo','note','known: reporting jobs use JIT')
  UNION ALL SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','alert_ack','finding_key',finding_key,'instance_name',instance) FROM a
  UNION ALL SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','note','finding_key',finding_key,'instance_name',instance,'note','vendor ticket open') FROM a) q`, time.Now(), prefix)
	return err
}
