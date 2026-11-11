package demo

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// SeedAlertRules writes a few alert rules of 0085 on the demo fleet, made by 'demo' through import_alert_rule as the UI
// would: rules for the tag demo on both engines (so a real fleet in the same repository is not covered), one
// instance's own override, and one rule switched off. It then has the repository judge them once at the seed's end
// (alert_rules_run), so the Alert rules page shows states and the Metrics grids colour their figures without a sender
// running; alert_rules_run judges EVERY rule of the repository at that time, so the seed judges only where every live
// rule is its own (a repository that also holds a real fleet's rules is left to its sender). A re-seed deletes only
// what an earlier seed made (client 'demo seed'). A rule the store refuses is an error, not a silent gap.
func SeedAlertRules(ctx context.Context, pool *pgxpool.Pool, prefix string, at time.Time) error {
	for _, sql := range []string{
		`DELETE FROM pgvigil.alert_rule_state WHERE rule_id IN (SELECT rule_id FROM pgvigil.alert_rules WHERE client = 'demo seed')`,
		`DELETE FROM pgvigil.alert_rule_fired WHERE rule_id IN (SELECT rule_id FROM pgvigil.alert_rules WHERE client = 'demo seed')`,
		`DELETE FROM pgvigil.alert_rules WHERE client = 'demo seed'`,
		`DELETE FROM pgvigil.alert_rule_log WHERE client = 'demo seed'`,
	} {
		if _, err := pool.Exec(ctx, sql); err != nil {
			return err
		}
	}
	var made, refused int
	if err := pool.QueryRow(ctx, `
WITH pg1 AS (SELECT name FROM pgvigil.instances
              WHERE 'demo' = ANY (tags) AND starts_with(name, $2) AND is_active AND engine = 'postgres' ORDER BY name LIMIT 1)
SELECT count(*) FILTER (WHERE r->>'outcome' = 'done'), count(*) FILTER (WHERE r->>'outcome' <> 'done') FROM (
SELECT pgvigil.import_alert_rule($1, p || jsonb_build_object('op', 'add', 'ui_user', 'demo', 'client', 'demo seed')) AS r FROM (
  SELECT jsonb_build_object('name','idle in transaction','metric','sessions.idle_in_txn','op_dir','above','warning',3,'critical',8,'for_minutes',5,'scope','tag','tag','demo') p
  UNION ALL SELECT jsonb_build_object('name','connections used','metric','sessions.connections_pct','op_dir','above','warning',70,'critical',90,'for_minutes',5,'scope','tag','tag','demo')
  UNION ALL SELECT jsonb_build_object('name','cache hit ratio','metric','database.cache_hit_pct','op_dir','below','warning',95,'critical',90,'for_minutes',15,'scope','tag','tag','demo')
  UNION ALL SELECT jsonb_build_object('name','host CPU','metric','host.cpu_pct','op_dir','above','warning',80,'critical',95,'for_minutes',10,'scope','tag','tag','demo')
  UNION ALL SELECT jsonb_build_object('name','blocked processes','metric','requests.blocked','op_dir','above','warning',1,'critical',5,'for_minutes',2,'scope','tag','tag','demo')
  UNION ALL SELECT jsonb_build_object('name','page life expectancy','metric','memory.ple','op_dir','below','warning',300,'for_minutes',10,'scope','tag','tag','demo')
  UNION ALL SELECT jsonb_build_object('name','SQL Server CPU','metric','cpu.sql_pct','op_dir','above','warning',70,'critical',90,'for_minutes',5,'scope','tag','tag','demo')
  UNION ALL SELECT jsonb_build_object('name','WAL rate','metric','server.wal_bytes_s','op_dir','above','warning',50000000,'for_minutes',10,'scope','tag','tag','demo')
  UNION ALL SELECT jsonb_build_object('metric','sessions.idle_in_txn','op_dir','above','warning',10,'for_minutes',5,'scope','instance','instance_name',pg1.name,
                                      'note','the batch loader holds its transactions on purpose') FROM pg1) q) x`, at, prefix).Scan(&made, &refused); err != nil {
		return err
	}
	if refused > 0 || made < 8 {
		return fmt.Errorf("%d demo rule(s) made, %d refused (pgvigil.alert_rule_log says why)", made, refused)
	}
	// one rule switched off, as the page's switch would
	if _, err := pool.Exec(ctx, `
SELECT pgvigil.import_alert_rule($1, jsonb_build_object('op', 'disable', 'ui_user', 'demo', 'client', 'demo seed', 'rule_id', r.rule_id))
  FROM pgvigil.alert_rules r WHERE r.client = 'demo seed' AND r.name = 'WAL rate' AND r.ended_at IS NULL`, at); err != nil {
		return err
	}
	_, err := pool.Exec(ctx, `
SELECT pgvigil.alert_rules_run($1)
 WHERE NOT EXISTS (SELECT 1 FROM pgvigil.alert_rules r WHERE r.ended_at IS NULL AND r.client IS DISTINCT FROM 'demo seed')`, at)
	return err
}
