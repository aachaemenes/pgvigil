package web

import (
	"errors"
	"net/http"
	"strings"
)

// The collector's error log (DBA Dash's Checks > DBA Dash ErrorLog: dbo.CollectionErrorLog_Get over
// dbo.CollectionErrorLogSearch): every run that did not end well, kept in collection_log (0001, its stage 0198), and the
// service's own failures where they are already stored - an alert send that failed or was refused (alert_log), a report
// mail that failed or was refused (report_mail_sends), a DBA Dash repository not read (dbadash_repositories, its last
// attempt only, a configured one). Those are '(the service)' rows: shown at the root and in a folder, never at one
// instance (DBA Dash's '(No instance)'), each with a link to the page where it is handled. One row set feeds every view,
// so a count always lists the rows it counts. Types: Error, Warning (a run that finished carrying a collector_error
// row), Skipped (hidden unless asked); pgvigil never retries a run, so there is no Retry. Stages: Connect, Collect,
// Import, Other (collection_error_class, 0198).

// sqlCollectorErrorsBase is the filtered row set f. $1 from, $2 to, $3 the instance (NULL = any), $4 a folder's
// instances (NULL = any), $5 a tag (NULL = any), $6 the service's rows only, $7 the collection, $8 the type, $9 the
// stage, $10 text in the note, $11 skips shown, $12 the no-permission pattern (q_frame.go).
const sqlCollectorErrorsBase = `
WITH scope AS (
  SELECT i.instance_id, i.name, i.engine
    FROM pgvigil.instances i
   WHERE ($3::int IS NULL OR i.instance_id = $3) AND ($4::int[] IS NULL OR i.instance_id = ANY ($4))
     AND ($5::text IS NULL OR $5 = ANY (i.tags))
), marks AS (
  -- the instance's acknowledgement: the highest log_id of its live 'collector errors' rows; a seen_state not of the
  -- form 'log_id:<n>' is never read (a CASE: PostgreSQL may run a WHERE's cast before its test)
  SELECT a.instance_id,
         max(CASE WHEN a.seen_state ~ '^log_id:[0-9]{1,18}$' THEN substring(a.seen_state from 8)::bigint END) AS mark
    FROM pgvigil.acks a
   WHERE a.kind = 'ack' AND a.check_key = 'collector errors' AND a.instance_id IS NOT NULL
     AND pgvigil.ack_live(a.ended_at, a.starts_at, a.until, now())
   GROUP BY a.instance_id
), e AS (
  SELECT l.log_id, l.snapshot_at AS at, l.instance_id, s.name AS instance, s.engine, l.collection,
         c.error_type AS type, c.error_stage AS stage, l.note, coalesce(l.log_id <= m.mark, false) AS acked, NULL::text AS link
    FROM pgvigil.collection_log l
    JOIN scope s ON s.instance_id = l.instance_id
    CROSS JOIN LATERAL pgvigil.collection_error_class(l.status, l.note, l.stage) c
    LEFT JOIN marks m ON m.instance_id = l.instance_id
   WHERE l.status IN ('error', 'partial', 'skipped') AND l.snapshot_at >= $1 AND l.snapshot_at < $2 AND NOT $6
  UNION ALL
  SELECT NULL, a.snapshot_at, NULL, '(the service)', NULL, 'alerts', 'Error', 'Other',
         CASE WHEN EXISTS (SELECT 1 FROM unnest(a.keys) k WHERE k LIKE 'test-%') THEN 'test send ' ELSE 'alert send ' END
           || a.outcome || ' on channel ' || coalesce(a.channel, '(none)') || coalesce(': ' || a.error, ''),
         false, '#/alerts'
    FROM pgvigil.alert_log a
   WHERE $3::int IS NULL AND a.outcome IN ('failed', 'refused') AND a.snapshot_at >= $1 AND a.snapshot_at < $2
  UNION ALL
  SELECT NULL, coalesce(m.done_at, m.requested_at), NULL, '(the service)', NULL, 'report mail', 'Error', 'Other',
         'report mail ' || m.outcome || ': ' || m.name || coalesce(': ' || m.error, ''), false, '#/reportmail'
    FROM pgvigil.report_mail_sends m
   WHERE $3::int IS NULL AND m.outcome IN ('failed', 'refused')
     AND coalesce(m.done_at, m.requested_at) >= $1 AND coalesce(m.done_at, m.requested_at) < $2
  UNION ALL
  SELECT NULL, d.read_at, NULL, '(the service)', NULL, 'DBA Dash import', 'Error', 'Other',
         'not read: ' || d.repository || coalesce(': ' || d.reason, ''), false, '#/dbadash'
    FROM pgvigil.dbadash_repositories d
   WHERE $3::int IS NULL AND d.status = 'not read' AND d.is_configured AND d.read_at >= $1 AND d.read_at < $2
), e2 AS (
  SELECT e.*, coalesce(e.note, '') ~* $12::text AS no_right FROM e
), f AS (
  SELECT * FROM e2 e
   WHERE ($7::text IS NULL OR e.collection = $7) AND ($8::text IS NULL OR lower(e.type) = lower($8))
     AND ($9::text IS NULL OR lower(e.stage) = lower($9)) AND ($10::text IS NULL OR strpos(lower(e.note), lower($10)) > 0)
     AND ($11 OR e.type <> 'Skipped')
)`

// sqlCollectorErrorsCounts is the counts of a group: each type set and each stage set adds up to total; 0 is NULL, so
// what is there stands out (DBA Dash's NULLIF).
const sqlCollectorErrorsCounts = `
       count(*)::int AS total,
       nullif(count(*) FILTER (WHERE f.type = 'Error'), 0)::int AS errors,
       nullif(count(*) FILTER (WHERE f.type = 'Warning'), 0)::int AS warnings,
       nullif(count(*) FILTER (WHERE f.type = 'Skipped'), 0)::int AS skipped,
       nullif(count(*) FILTER (WHERE f.stage = 'Connect'), 0)::int AS connect,
       nullif(count(*) FILTER (WHERE f.stage = 'Collect'), 0)::int AS collect,
       nullif(count(*) FILTER (WHERE f.stage = 'Import'), 0)::int AS import,
       nullif(count(*) FILTER (WHERE f.stage = 'Other'), 0)::int AS other,
       min(f.at) AS first_at, max(f.at) AS last_at,
       left((array_agg(f.note ORDER BY f.at DESC, f.log_id DESC NULLS LAST))[1], 1000) AS last_message,
       (array_agg(f.note ORDER BY f.at DESC, f.log_id DESC NULLS LAST))[1] AS last_message_full`

// The suggestions (DBA Dash's dbo.CollectionErrorSuggestion, its WMI rule in pgvigil's own two known causes): 2 or
// more collections failing on a missing right ('rights'), every error of the instance a failed connection
// ('unreachable').
const sqlCollectorErrorsSuggest = `
  g AS (
    SELECT f.instance_id, f.instance, min(f.engine) AS engine,
           count(DISTINCT f.collection) FILTER (WHERE f.type IN ('Error', 'Warning') AND f.no_right) AS rights,
           count(*) FILTER (WHERE f.type = 'Error') AS errs,
           count(*) FILTER (WHERE f.type = 'Error' AND f.stage = 'Connect') AS conns
      -- over the range and scope only, never the page's filters: a Stage filter must not make an instance 'unreachable'
      FROM e2 f WHERE f.instance_id IS NOT NULL AND ($11 OR f.type <> 'Skipped') GROUP BY f.instance_id, f.instance
  ), sg AS (
    SELECT g.instance_id, g.instance,
           CASE WHEN g.rights >= 2 THEN 'rights' WHEN g.errs > 0 AND g.errs = g.conns THEN 'unreachable' END AS kind,
           CASE WHEN g.rights >= 2 THEN 'The monitor login lacks rights for ' || g.rights || ' collections: grant what docs/'
                      || CASE WHEN g.engine = 'sqlserver' THEN 'sqlserver' ELSE 'postgres' END || '.md lists, or turn them off.'
                WHEN g.errs > 0 AND g.errs = g.conns THEN 'Unreachable: every error is a failed connection (the server unreachable finding).' END AS text,
           CASE WHEN g.rights >= 2 THEN '#/collectiondates?i=' || g.instance_id
                WHEN g.errs > 0 AND g.errs = g.conns THEN '#/findings?i=' || g.instance_id END AS help
      FROM g
  )`

const sqlCollectorErrorsByInstance = sqlCollectorErrorsBase + `, ` + sqlCollectorErrorsSuggest + `
SELECT f.instance_id, f.instance, count(DISTINCT f.collection)::int AS collections,` + sqlCollectorErrorsCounts + `,
       min(sg.text) AS suggestion, min(sg.help) AS help, min(m.mark) AS mark, max(f.log_id) AS max_log_id,
       CASE WHEN min(m.mark) IS NOT NULL THEN count(*) FILTER (WHERE NOT f.acked)::int END AS new_since_mark
  FROM f
  LEFT JOIN sg ON sg.instance_id = f.instance_id
  LEFT JOIN marks m ON m.instance_id = f.instance_id
 GROUP BY f.instance_id, f.instance
 ORDER BY count(*) FILTER (WHERE f.type = 'Error') DESC, count(*) DESC, f.instance`

const sqlCollectorErrorsByCollection = sqlCollectorErrorsBase + `
SELECT f.collection, count(DISTINCT f.instance)::int AS instances,` + sqlCollectorErrorsCounts + `,
       max(f.log_id) AS max_log_id
  FROM f
 GROUP BY f.collection
 ORDER BY count(*) FILTER (WHERE f.type = 'Error') DESC, count(*) DESC, f.collection`

const sqlCollectorErrorsList = sqlCollectorErrorsBase + `
SELECT f.log_id, f.at, f.instance_id, f.instance, f.collection, f.type, f.stage, f.note, f.acked, f.link
  FROM f
 ORDER BY f.at DESC, f.log_id DESC NULLS LAST
 LIMIT 5000`

// one card per suggestion kind, naming its instances (DBA Dash's dbo.CollectionErrorInsight: one card, not a line per row)
const sqlCollectorErrorsInsights = sqlCollectorErrorsBase + `, ` + sqlCollectorErrorsSuggest + `
SELECT sg.kind, string_agg(sg.instance, ', ' ORDER BY sg.instance) AS instances,
       CASE sg.kind WHEN 'rights' THEN 'The monitor login lacks rights for two or more collections on these instances: grant what the engine''s docs list, or turn the collections off.'
                    ELSE 'Every error of these instances is a failed connection: see the server unreachable finding.' END AS text,
       NULL::text AS help
  FROM sg WHERE sg.kind IS NOT NULL
 GROUP BY sg.kind
 ORDER BY sg.kind`

// the live acknowledgement of each instance in scope: its mark and the rows that make it (Unacknowledge ends them all)
const sqlCollectorErrorsMarks = `
SELECT a.instance_id, i.name AS instance,
       max(CASE WHEN a.seen_state ~ '^log_id:[0-9]{1,18}$' THEN substring(a.seen_state from 8)::bigint END) AS mark,
       array_agg(a.ack_id ORDER BY a.ack_id) AS ack_ids
  FROM pgvigil.acks a
  JOIN pgvigil.instances i ON i.instance_id = a.instance_id
 WHERE a.kind = 'ack' AND a.check_key = 'collector errors' AND pgvigil.ack_live(a.ended_at, a.starts_at, a.until, now())
   AND ($1::int IS NULL OR i.instance_id = $1) AND ($2::int[] IS NULL OR i.instance_id = ANY ($2))
   AND ($3::text IS NULL OR $3 = ANY (i.tags))
 GROUP BY a.instance_id, i.name
 ORDER BY i.name`

var collectorErrorTypes = map[string]string{"error": "Error", "warning": "Warning", "skipped": "Skipped"}
var collectorErrorStages = map[string]string{"connect": "Connect", "collect": "Collect", "import": "Import", "other": "Other"}

// CollectorErrors is GET /api/collectorerrors?[instance=|instances=][&tag=][&service=1][&from=&to=]
// [&view=instance|collection|error][&coll=][&type=][&stage=][&q=][&skipped=1]: parts rows, insights, marks. The view
// defaults to a row per instance, a row per collection at one instance (DBA Dash's ErrorLogView.OnContextChanged).
func (s *Server) CollectorErrors(w http.ResponseWriter, r *http.Request) {
	id, ids, err := storageScope(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	view := q.Get("view")
	if view == "" {
		view = "instance"
		if id > 0 {
			view = "collection"
		}
	}
	var rows string
	switch view {
	case "instance":
		rows = sqlCollectorErrorsByInstance
	case "collection":
		rows = sqlCollectorErrorsByCollection
	case "error":
		rows = sqlCollectorErrorsList
	default:
		writeErr(w, http.StatusBadRequest, errors.New("view must be instance, collection or error"))
		return
	}
	word := func(name string, known map[string]string) (any, error) {
		v := strings.TrimSpace(q.Get(name))
		if v == "" {
			return nil, nil
		}
		if w, ok := known[strings.ToLower(v)]; ok {
			return w, nil
		}
		keys := make([]string, 0, len(known))
		for _, w := range known {
			keys = append(keys, w)
		}
		return nil, errors.New(name + " must be one of " + strings.Join(keys, ", "))
	}
	typ, err := word("type", collectorErrorTypes)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	stage, err := word("stage", collectorErrorStages)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	text := func(name string, max int) (any, error) {
		v := strings.TrimSpace(q.Get(name))
		if v == "" {
			return nil, nil
		}
		if len(v) > max {
			return nil, errors.New(name + " is too long")
		}
		return v, nil
	}
	coll, err := text("coll", 200)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	note, err := text("q", 200)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	tag, err := text("tag", 200)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var inst, folder any
	if id > 0 {
		inst = id
	}
	if ids != nil {
		folder = ids
	}
	service := q.Get("service") == "1"
	skipped := q.Get("skipped") == "1"
	args := []any{from, to, inst, folder, tag, service, coll, typ, stage, note, skipped, noPermission}
	s.multiPart(w, r, []part{
		{"rows", rows, args},
		{"insights", sqlCollectorErrorsInsights, args},
		{"marks", sqlCollectorErrorsMarks, []any{inst, folder, tag}},
	})
}
