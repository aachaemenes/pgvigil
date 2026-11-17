package web

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestSummaryServiceBrokerD5 (control audit D5; DBA Dash's Summary Service Broker column, Summary_Upd.sql L193-196 /
// L280-281: ServiceBrokerInstanceInfo's ServiceBrokerStatus): the SQL Server Summary has a 'servicebroker' cell - D4
// a's instance status (sqlBrokerInstance): its critical or warning count with the issues as detail, the value 'N/A' with
// nothing to report (and the collection never run is N/A, not 'never': DBA Dash's is off by default). Join line 12 (d)
// names fleet.ts' cell line, its owner's.
func TestSummaryServiceBrokerD5(t *testing.T) {
	j, err := os.ReadFile("../../scripts/PARITY-S3-join-lines.sql")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(j), "mssql: ['servicebroker', 'summary', 'Service Broker']") {
		t.Error("join line 12 (d) does not name fleet.ts' servicebroker cell line")
	}
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	sfx := time.Now().UnixNano() % 1000000000
	var ids []int
	for _, n := range []string{"bad", "quiet"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("sbsum-%s-%d", n, sfx)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_broker_queue WHERE instance_id = ANY ($1)`, `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`} {
			if _, err := pool.Exec(context.Background(), q, ids); err != nil {
				t.Error(err)
			}
		}
	}()
	at := time.Now().UTC().Truncate(time.Minute)
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_broker_queue (instance_id, database_name, schema_name, queue_name, is_receive_enabled, is_enqueue_enabled, message_count, first_seen, snapshot_at)
	                             VALUES ($1, 'Sales', 'dbo', 'q1', false, true, 0, $2, $2)`, ids[0], at); err != nil {
		t.Fatal(err)
	}
	rs, err := pool.Query(ctx, sqlMSSQLSummaryCells, `{}`, 3600)
	if err != nil {
		t.Fatal(err)
	}
	defer rs.Close()
	got := map[int]string{}
	for rs.Next() {
		var iid, c, w int
		var key, state string
		var sampled bool
		var value, errText *string
		var detail []string
		var readAt, since *time.Time
		if err := rs.Scan(&iid, &key, &state, &sampled, &c, &w, &value, &detail, &readAt, &errText, &since); err != nil {
			t.Fatal(err)
		}
		if key == "servicebroker" && (iid == ids[0] || iid == ids[1]) {
			v := "<nil>"
			if value != nil {
				v = *value
			}
			got[iid] = fmt.Sprint(state, " ", c, "/", w, " ", v, " ", len(detail) > 0)
		}
	}
	if err := rs.Err(); err != nil {
		t.Fatal(err)
	}
	if got[ids[0]] != "n/a 1/0 <nil> true" || got[ids[1]] != "n/a 0/0 N/A false" {
		t.Errorf("servicebroker cells: bad %q, quiet %q; want 'n/a 1/0 <nil> true' (the collection not run, a disabled queue) and 'n/a 0/0 N/A false'", got[ids[0]], got[ids[1]])
	}
}
