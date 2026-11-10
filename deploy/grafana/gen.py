#!/usr/bin/env python3
"""Generates pgvigil's Grafana dashboards (deploy/grafana/dashboards/*.json): python3 deploy/grafana/gen.py deploy/grafana/dashboards.
Change this file, never a JSON file by hand; scripts/proof-grafana.sh reads the JSON."""
import json, os, sys

OUT = sys.argv[1]
DS = {"type": "grafana-postgresql-datasource", "uid": "${datasource}"}
TF, TT = "$__timeFrom()", "$__timeTo()"
I = "$instance"
NAME = "pgvigil.versions_fleet"  # instance_id -> instance, platform (a view over every instance)


def target(sql, fmt="table", ref="A"):
    return {"refId": ref, "datasource": DS, "editorMode": "code", "rawQuery": True, "format": fmt, "rawSql": " ".join(sql.split())}


class Dash:
    def __init__(self, uid, title, desc, instance_var=True, extra_vars=None):
        self.uid, self.title, self.desc = uid, title, desc
        self.panels, self.x, self.y, self.rowh = [], 0, 0, 0
        self.instance_var, self.extra_vars = instance_var, extra_vars or []

    def _place(self, w, h):
        if self.x + w > 24:
            self.x, self.y, self.rowh = 0, self.y + self.rowh, 0
        pos = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.x += w
        self.rowh = max(self.rowh, h)
        return pos

    def row(self, title):
        if self.x:
            self.x, self.y, self.rowh = 0, self.y + self.rowh, 0
        self.panels.append({"type": "row", "title": title, "collapsed": False, "panels": [],
                            "id": len(self.panels) + 1, "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}})
        self.y += 1

    def add(self, kind, title, sql, w=12, h=8, fmt="table", desc="", unit=None, options=None, field=None, overrides=None):
        fc = {"defaults": {}, "overrides": overrides or []}
        if unit:
            fc["defaults"]["unit"] = unit
        if field:
            fc["defaults"].update(field)
        p = {"id": len(self.panels) + 1, "type": kind, "title": title, "description": desc, "datasource": DS,
             "gridPos": self._place(w, h), "targets": [target(sql, fmt)], "fieldConfig": fc, "options": options or {}}
        self.panels.append(p)
        return p

    def table(self, title, sql, w=24, h=9, desc="", overrides=None):
        return self.add("table", title, sql, w, h, desc=desc, overrides=overrides,
                        options={"showHeader": True, "cellHeight": "sm", "footer": {"show": False}},
                        field={"custom": {"filterable": True, "inspect": True}})

    def stat(self, title, sql, w=4, h=4, unit=None, desc="", red=None, text=False):
        steps = [{"color": "green", "value": None}]
        if red is not None:
            steps.append({"color": "red", "value": red})
        return self.add("stat", title, sql, w, h, desc=desc, unit=unit,
                        options={"reduceOptions": {"calcs": ["lastNotNull"], "fields": "/.*/" if text else "", "values": False},
                                 "colorMode": "value" if red is not None else "none", "graphMode": "none", "textMode": "auto"},
                        field={"thresholds": {"mode": "absolute", "steps": steps}})

    def ts(self, title, sql, w=12, h=8, unit=None, desc="", bars=False, stack=False):
        custom = {"drawStyle": "bars" if bars else "line", "fillOpacity": 60 if bars else 10, "lineWidth": 1,
                  "showPoints": "never", "spanNulls": False}
        if stack:
            custom["stacking"] = {"mode": "normal", "group": "A"}
        return self.add("timeseries", title, sql, w, h, fmt="time_series", desc=desc, unit=unit,
                        options={"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                                 "tooltip": {"mode": "multi", "sort": "desc"}},
                        field={"custom": custom})

    def bars(self, title, sql, w=12, h=8, unit=None, desc=""):
        return self.add("bargauge", title, sql, w, h, desc=desc, unit=unit,
                        options={"orientation": "horizontal", "displayMode": "basic", "showUnfilled": True,
                                 "reduceOptions": {"calcs": [], "fields": "", "values": True}, "valueMode": "color"},
                        field={"thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}})

    def pie(self, title, sql, w=8, h=8, desc=""):
        return self.add("piechart", title, sql, w, h, desc=desc,
                        options={"pieType": "donut", "legend": {"displayMode": "table", "placement": "right", "showLegend": True, "values": ["value"]},
                                 "reduceOptions": {"calcs": [], "fields": "", "values": True}, "tooltip": {"mode": "single"}})

    def json(self):
        tvars = [{"type": "datasource", "name": "datasource", "label": "Repository", "query": "grafana-postgresql-datasource",
                  "current": {"text": "pgvigil", "value": "pgvigil"}, "hide": 0, "refresh": 1, "regex": ""}]
        if self.instance_var:
            q = f"SELECT instance AS __text, instance_id AS __value FROM {NAME} ORDER BY instance"
            tvars.append({"type": "query", "name": "instance", "label": "Instance", "datasource": DS, "query": q,
                          "definition": q, "refresh": 1, "sort": 0, "multi": False, "includeAll": False, "hide": 0})
        tvars += self.extra_vars
        return {"uid": self.uid, "title": self.title, "description": self.desc, "tags": ["pgvigil"], "editable": True,
                "schemaVersion": 41, "version": 1, "graphTooltip": 1, "timezone": "browser", "refresh": "1m",
                "time": {"from": "now-24h", "to": "now"}, "fiscalYearStartMonth": 0, "liveNow": False,
                "templating": {"list": tvars}, "annotations": {"list": []},
                "links": [{"type": "dashboards", "tags": ["pgvigil"], "asDropdown": True, "title": "pgvigil",
                           "includeVars": True, "keepTime": True}],
                "panels": self.panels}

    def write(self, slug):
        with open(os.path.join(OUT, f"{slug}.json"), "w") as f:
            json.dump(self.json(), f, indent=2)
            f.write("\n")


def link_to_instance(dash_uid="pgvigil-instance"):
    """A table override: the instance column links to the instance overview, instance_id is hidden."""
    return [
        {"matcher": {"id": "byName", "options": "instance"}, "properties": [{"id": "links", "value": [
            {"title": "Instance overview", "url": f"/d/{dash_uid}?var-instance=${{__data.fields.instance_id}}&${{__url_time_range}}&${{datasource:queryparam}}"}]}]},
        {"matcher": {"id": "byName", "options": "instance_id"}, "properties": [{"id": "custom.hidden", "value": True}]},
    ]


SEV_ORDER = "CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END"
RATE_DB = f"pgvigil.dbstats_rate({I}, {TF}, {TT})"
RATE_IO = f"pgvigil.iostats_rate({I}, {TF}, {TT})"
RATE_SRV = f"pgvigil.serverstats_rate({I}, {TF}, {TT})"
LATEST_ACT = f"(SELECT max(snapshot_at) FROM pgvigil.activity_latest WHERE instance_id = {I})"

# 1. Fleet summary -------------------------------------------------------------------------------------------
d = Dash("pgvigil-fleet", "pgvigil / Fleet summary", "Every monitored instance: findings, sessions, backups, corruption, storage.", instance_var=False)
d.stat("Instances", f"SELECT count(*) AS instances FROM {NAME}")
d.stat("Critical findings", "SELECT count(*) AS critical FROM pgvigil.findings WHERE severity = 'critical'", red=1)
d.stat("Warnings", "SELECT count(*) AS warnings FROM pgvigil.findings WHERE severity = 'warning'")
d.stat("Blocked sessions now", "SELECT count(*) AS blocked FROM pgvigil.activity_latest WHERE cardinality(blocking_pids) > 0", red=1,
       desc="Sessions waiting on a lock at each instance's latest activity snapshot.")
d.stat("Job failures (7 days)", "SELECT coalesce(sum(failures_7d), 0) AS failures FROM pgvigil.job_report", red=1)
d.stat("Volumes full within 30 days", "SELECT count(*) AS volumes FROM pgvigil.volume_forecast(NULL) WHERE days_until_full < 30", red=1)
d.table("Instances", f"""
SELECT v.instance_id, v.instance, v.platform, v.server_version, v.last_restart,
       coalesce(f.critical, 0) AS critical, coalesce(f.warning, 0) AS warning,
       coalesce(a.sessions, 0) AS sessions, coalesce(a.blocked, 0) AS blocked,
       b.archiver_failing, c.data_checksums, c.events_7d AS corruption_events_7d, v.pending_actions
  FROM {NAME} v
  LEFT JOIN (SELECT instance_id, count(*) FILTER (WHERE severity = 'critical') AS critical,
                    count(*) FILTER (WHERE severity = 'warning') AS warning
               FROM pgvigil.findings GROUP BY instance_id) f USING (instance_id)
  LEFT JOIN (SELECT instance_id, count(*) AS sessions, count(*) FILTER (WHERE cardinality(blocking_pids) > 0) AS blocked
               FROM pgvigil.activity_latest GROUP BY instance_id) a USING (instance_id)
  LEFT JOIN pgvigil.backup_status b USING (instance_id)
  LEFT JOIN pgvigil.corruption_summary c USING (instance_id)
 ORDER BY critical DESC, warning DESC, v.instance""", h=14, overrides=link_to_instance())
d.table("Critical and warning findings", f"""
SELECT v.instance_id, v.instance, f.severity, f.source, f.setting AS "check", f.value, f.detail, f.suggested, f.at
  FROM pgvigil.findings f JOIN {NAME} v USING (instance_id)
 WHERE f.severity IN ('critical', 'warning')
 ORDER BY {SEV_ORDER}, v.instance, f.setting""", h=12, overrides=link_to_instance())
d.table("Storage forecast", """
SELECT instance_id, instance, platform, volume, kind, free_pct, headroom_pct, growth_7d_per_day, days_until_full, holds_data
  FROM pgvigil.volume_forecast(NULL) ORDER BY days_until_full NULLS LAST, free_pct""", w=12, overrides=link_to_instance())
d.table("Versions", f"""
SELECT instance_id, instance, platform, server_version, engine_version, auto_minor_version_upgrade, next_maintenance,
       upgrade_targets, extensions_outdated, collation_mismatches
  FROM {NAME} ORDER BY server_version_num, instance""", w=12, overrides=link_to_instance())
d.write("01-fleet-summary")

# 2. Instance overview ---------------------------------------------------------------------------------------
d = Dash("pgvigil-instance", "pgvigil / Instance overview", "One instance: version, sessions, throughput, cache, host and its findings.")
d.stat("Version", f"SELECT server_version FROM {NAME} WHERE instance_id = {I}", text=True)
d.stat("Last restart", f"SELECT extract(epoch FROM last_restart) * 1000 AS last_restart FROM {NAME} WHERE instance_id = {I}", unit="dateTimeFromNow")
d.stat("Sessions now", f"SELECT count(*) AS sessions FROM pgvigil.activity_latest WHERE instance_id = {I}")
d.stat("Blocked now", f"SELECT count(*) AS blocked FROM pgvigil.activity_latest WHERE instance_id = {I} AND cardinality(blocking_pids) > 0", red=1)
d.stat("Critical findings", f"SELECT count(*) AS critical FROM pgvigil.findings WHERE instance_id = {I} AND severity = 'critical'", red=1)
d.stat("CPU", f"SELECT cpu_pct FROM pgvigil.host_latest WHERE instance_id = {I}", unit="percent",
       desc="The host's (or the cloud metric's) CPU at its latest read; empty where no host source is configured.")
d.ts("Connections per database", f"""
SELECT snapshot_at AS time, datname AS metric, numbackends AS value
  FROM {RATE_DB} WHERE NOT reset ORDER BY 1, 2""")
d.ts("Transactions per second", f"""
SELECT snapshot_at AS time,
       round(sum(xact_commit)::numeric / max(interval_secs), 2) AS commits,
       round(sum(xact_rollback)::numeric / max(interval_secs), 2) AS rollbacks
  FROM {RATE_DB} WHERE interval_secs > 0 GROUP BY snapshot_at HAVING NOT bool_or(reset) ORDER BY 1""", unit="ops")
d.ts("Cache hit ratio", f"""
SELECT snapshot_at AS time,
       round(100.0 * sum(blks_hit) / nullif(sum(blks_hit) + sum(blks_read), 0), 2) AS hit_pct
  FROM {RATE_DB} WHERE interval_secs > 0 GROUP BY snapshot_at HAVING NOT bool_or(reset) ORDER BY 1""", unit="percent")
d.ts("Temp files and deadlocks", f"""
SELECT snapshot_at AS time, sum(temp_files) AS temp_files, sum(deadlocks) AS deadlocks
  FROM {RATE_DB} WHERE interval_secs > 0 GROUP BY snapshot_at HAVING NOT bool_or(reset) ORDER BY 1""")
d.table("Findings", f"""
SELECT f.severity, f.source, f.setting AS "check", f.value, f.detail, f.suggested, f.at
  FROM pgvigil.findings f WHERE f.instance_id = {I} ORDER BY {SEV_ORDER}, f.source, f.setting""", h=12)
d.table("Host", f"""
SELECT source, host_name, os_name, os_version, cpu_model, cpu_cores, logical_cpus, mem_total, mem_used, swap_used,
       load1, load5, load15, uptime_secs, metrics_at
  FROM pgvigil.host_latest WHERE instance_id = {I}""", h=5)
d.write("02-instance-overview")

# 3. Running queries and blocking ----------------------------------------------------------------------------
d = Dash("pgvigil-activity", "pgvigil / Running queries and blocking",
         "The latest activity snapshot, its blocking chains, the lock tree at the range's end and the long statements of the range.")
d.stat("Active", f"SELECT count(*) AS active FROM pgvigil.activity_latest WHERE instance_id = {I} AND state = 'active'")
d.stat("Idle in transaction", f"SELECT count(*) AS idle_in_xact FROM pgvigil.activity_latest WHERE instance_id = {I} AND state LIKE 'idle in transaction%'", red=1)
d.stat("Waiting on a lock", f"SELECT count(*) AS lock_waits FROM pgvigil.activity_latest WHERE instance_id = {I} AND wait_event_type = 'Lock'", red=1)
d.stat("Blocking others", f"SELECT count(*) AS blockers FROM pgvigil.activity_latest WHERE instance_id = {I} AND is_blocker", red=1)
d.stat("Oldest transaction", f"""
SELECT extract(epoch FROM max(snapshot_at - xact_start)) AS secs FROM pgvigil.activity_latest WHERE instance_id = {I}""", unit="s")
d.stat("Snapshot", f"SELECT extract(epoch FROM max(snapshot_at)) * 1000 AS snapshot_at FROM pgvigil.activity_latest WHERE instance_id = {I}", unit="dateTimeFromNow")
d.table("Blocking chains (latest snapshot)", f"""
SELECT head_pid, depth, pid, state, wait_event, in_cycle, head_state, head_backend_type, head_query, waiter_query
  FROM pgvigil.blocking_chains({I}, {LATEST_ACT}) ORDER BY head_pid, depth, pid""",
        desc="The head is the session that holds and waits on no lock itself: its transaction and last statement are the cause.")
d.table("Lock tree at the range's end", f"""
SELECT snapshot_at, top_blocker, level, pid, blocked_by::text AS blocked_by, blocked, state, wait, xact_start, query_start,
       datname, usename, application_name
  FROM pgvigil.lock_tree({I}, {TT}) ORDER BY path""")
d.table("Sessions (latest snapshot)", f"""
SELECT pid, datname, usename, application_name, client, state,
       coalesce(wait_event_type || ':' || wait_event, '') AS wait,
       extract(epoch FROM snapshot_at - xact_start)::int AS xact_secs,
       extract(epoch FROM snapshot_at - CASE WHEN state = 'active' THEN query_start ELSE state_change END)::int AS state_secs,
       blocking_pids::text AS blocked_by, is_blocker, backend_xmin_age, backend_type, query_id
  FROM pgvigil.activity_latest WHERE instance_id = {I}
 ORDER BY is_blocker DESC, cardinality(blocking_pids) DESC, xact_start NULLS LAST""", h=10)
d.table("Long-running statements in the range (5 s and over)", f"""
SELECT first_seen, last_seen, at_least_secs, pid, state, datname, usename, application_name, top_wait,
       was_blocked, was_blocker, query
  FROM pgvigil.slow_in_window({I}, {TF}, {TT}, 5, 100) ORDER BY at_least_secs DESC""", h=10)
d.ts("Connections", f"""
SELECT snapshot_at AS time, sum(numbackends) AS connections
  FROM {RATE_DB} GROUP BY snapshot_at HAVING NOT bool_or(reset) ORDER BY 1""", w=24, h=6)
d.write("03-activity-blocking")

# 4. Statements ----------------------------------------------------------------------------------------------
order_var = {"type": "custom", "name": "order", "label": "Order by", "query": "time,calls,io,mean,rows,temp,wal",
             "current": {"text": "time", "value": "time"}, "hide": 0, "multi": False, "includeAll": False,
             "options": [{"text": o, "value": o, "selected": o == "time"} for o in "time,calls,io,mean,rows,temp,wal".split(",")]}
limit_var = {"type": "custom", "name": "limit", "label": "Rows", "query": "20,50,100",
             "current": {"text": "50", "value": "50"}, "hide": 0, "multi": False, "includeAll": False,
             "options": [{"text": o, "value": o, "selected": o == "50"} for o in ("20", "50", "100")]}
d = Dash("pgvigil-statements", "pgvigil / Statements",
         "pg_stat_statements over the range (the delta between snapshots) and the slow statements of the server log.",
         extra_vars=[order_var, limit_var])
d.bars("Top 10 by total execution time", f"""
SELECT left(regexp_replace(coalesce(query, queryid::text), '\\s+', ' ', 'g'), 90) AS statement, round(total_exec_ms::numeric, 0) AS total_ms
  FROM pgvigil.top_statements_by({I}, {TF}, {TT}, 'time', 10) ORDER BY total_exec_ms DESC""", unit="ms", w=24, h=9)
d.table("Top statements", f"""
SELECT queryid, datname, usename, calls, round(total_exec_ms::numeric, 1) AS total_ms, round(mean_exec_ms::numeric, 2) AS mean_ms,
       rows, hit_pct, io_blks, round(blk_read_ms::numeric, 1) AS blk_read_ms, temp_blks_written, wal_bytes, query
  FROM pgvigil.top_statements_by({I}, {TF}, {TT}, '$order', $limit)""", h=12,
        desc="The query text is what the collector stored under its query_text policy (full, normalized or none).")
d.stat("Slow statements (log)", f"SELECT statements FROM pgvigil.slow_totals({I}, {TF}, {TT}, 0)")
d.stat("Distinct shapes", f"SELECT shapes FROM pgvigil.slow_totals({I}, {TF}, {TT}, 0)")
d.stat("Total slow time", f"SELECT total_ms FROM pgvigil.slow_totals({I}, {TF}, {TT}, 0)", unit="ms")
d.stat("Slowest", f"SELECT max_ms FROM pgvigil.slow_totals({I}, {TF}, {TT}, 0)", unit="ms")
d.ts("Slow statements per day (UTC) by duration", f"""
SELECT (day::timestamp AT TIME ZONE 'UTC') AS time, under_1s, s1_to_10 AS "1-10 s", s10_to_60 AS "10-60 s", over_60s AS "over 60 s"
  FROM pgvigil.slow_histogram({I}, {TF}, {TT}, 0, 'UTC') ORDER BY 1""", w=24, h=7, bars=True, stack=True)
d.table("Slow statement shapes (log)", f"""
SELECT statements, round(total_ms::numeric, 0) AS total_ms, round(mean_ms::numeric, 1) AS mean_ms, round(max_ms::numeric, 0) AS max_ms,
       first_at, last_at, databases, users, queryid, example
  FROM pgvigil.slow_top({I}, {TF}, {TT}, 0, 50)""", h=10)
d.write("04-statements")

# 5. Counters and IO -----------------------------------------------------------------------------------------
d = Dash("pgvigil-io", "pgvigil / Counters and IO", "pg_stat_database, pg_stat_io, the checkpointer and WAL, the host's disks and the cloud's IO metrics.")
d.ts("Rows per second", f"""
SELECT snapshot_at AS time,
       round(sum(tup_returned)::numeric / max(interval_secs), 1) AS returned, round(sum(tup_fetched)::numeric / max(interval_secs), 1) AS fetched,
       round(sum(tup_inserted)::numeric / max(interval_secs), 1) AS inserted, round(sum(tup_updated)::numeric / max(interval_secs), 1) AS updated,
       round(sum(tup_deleted)::numeric / max(interval_secs), 1) AS deleted
  FROM {RATE_DB} WHERE interval_secs > 0 GROUP BY snapshot_at HAVING NOT bool_or(reset) ORDER BY 1""", unit="rowsps")
d.ts("Block read and write time (track_io_timing)", f"""
SELECT snapshot_at AS time,
       round((sum(blk_read_time) / max(interval_secs))::numeric, 3) AS read_ms_per_s,
       round((sum(blk_write_time) / max(interval_secs))::numeric, 3) AS write_ms_per_s,
       round((sum(blk_read_time) / nullif(sum(blks_read), 0))::numeric, 4) AS ms_per_block_read
  FROM {RATE_DB} WHERE interval_secs > 0 GROUP BY snapshot_at HAVING NOT bool_or(reset) ORDER BY 1""", unit="ms")
d.ts("Temp bytes per second", f"""
SELECT snapshot_at AS time, round(sum(temp_bytes)::numeric / max(interval_secs), 0) AS temp_bytes_s
  FROM {RATE_DB} WHERE interval_secs > 0 GROUP BY snapshot_at HAVING NOT bool_or(reset) ORDER BY 1""", unit="Bps")
d.ts("pg_stat_io throughput", f"""
SELECT snapshot_at AS time,
       round(sum(read_bytes) / max(interval_secs), 0) AS read_bytes_s, round(sum(write_bytes) / max(interval_secs), 0) AS write_bytes_s,
       round(sum(extend_bytes) / max(interval_secs), 0) AS extend_bytes_s
  FROM {RATE_IO} WHERE interval_secs > 0 GROUP BY snapshot_at HAVING NOT bool_or(reset) ORDER BY 1""", unit="Bps",
     desc="PostgreSQL 16 and later; empty on older versions.")
d.ts("Checkpoints", f"""
SELECT snapshot_at AS time, checkpoints_timed AS timed, checkpoints_req AS requested,
       round(coalesce(buffers_checkpoint, 0)::numeric / interval_secs, 2) AS buffers_per_s
  FROM {RATE_SRV} WHERE interval_secs > 0 AND NOT reset ORDER BY 1""")
d.ts("WAL bytes per second", f"""
SELECT snapshot_at AS time, round(wal_bytes / interval_secs, 0) AS wal_bytes_s, round(wal_fpi::numeric / interval_secs, 2) AS full_page_images_s
  FROM {RATE_SRV} WHERE interval_secs > 0 AND NOT reset ORDER BY 1""", unit="Bps")
d.ts("Host disks (bytes per second)", f"""
SELECT snapshot_at AS time, device || ' read' AS metric, read_bytes_s AS value
  FROM pgvigil.host_io_rate({I}, {TF}, {TT}) WHERE interval_secs > 0
UNION ALL
SELECT snapshot_at, device || ' write', write_bytes_s
  FROM pgvigil.host_io_rate({I}, {TF}, {TT}) WHERE interval_secs > 0
 ORDER BY 1, 2""", unit="Bps", desc="system_stats on a self-managed host; empty elsewhere.")
d.ts("Host disk latency", f"""
SELECT snapshot_at AS time, device || ' read' AS metric, read_ms_per_op AS value
  FROM pgvigil.host_io_rate({I}, {TF}, {TT}) WHERE interval_secs > 0
UNION ALL
SELECT snapshot_at, device || ' write', write_ms_per_op
  FROM pgvigil.host_io_rate({I}, {TF}, {TT}) WHERE interval_secs > 0
 ORDER BY 1, 2""", unit="ms")
d.table("pg_stat_io by backend, object and context", f"""
SELECT backend_type, object, context, sum(reads) AS reads, sum(read_bytes) AS read_bytes,
       round((sum(read_time) / nullif(sum(reads), 0))::numeric, 3) AS ms_per_read,
       sum(writes) AS writes, sum(write_bytes) AS write_bytes, sum(extends) AS extends, sum(hits) AS hits,
       round(100.0 * sum(hits) / nullif(sum(hits) + sum(reads), 0), 1) AS hit_pct, sum(evictions) AS evictions, sum(fsyncs) AS fsyncs
  FROM {RATE_IO} WHERE NOT reset GROUP BY backend_type, object, context
HAVING coalesce(sum(reads), 0) + coalesce(sum(writes), 0) + coalesce(sum(extends), 0) + coalesce(sum(hits), 0) + coalesce(sum(fsyncs), 0) > 0
 ORDER BY coalesce(sum(read_bytes), 0) + coalesce(sum(write_bytes), 0) DESC LIMIT 100""", h=10)
d.table("Cloud IO metrics (latest)", f"""
SELECT metric, value, unit, stat, dim, source, at FROM pgvigil.cloud_io_latest WHERE instance_id = {I} ORDER BY metric, dim""", h=8)
d.table("IO findings", f"""
SELECT f.severity, f.setting AS "check", f.value, f.detail, f.suggested, f.at
  FROM pgvigil.io_findings f WHERE f.instance_id = {I} ORDER BY {SEV_ORDER}, f.setting""", h=6)
d.write("05-counters-io")

# 6. Replication ---------------------------------------------------------------------------------------------
d = Dash("pgvigil-replication", "pgvigil / Replication", "Senders, receivers, slots, publications and Aurora replicas across the fleet, with the xmin holders.", instance_var=False)
d.stat("Largest lag", "SELECT max(lag_bytes) AS lag_bytes FROM pgvigil.replication_latest", unit="bytes")
d.stat("Longest replay lag", "SELECT max(lag_secs) AS lag_secs FROM pgvigil.replication_latest", unit="s")
d.stat("Inactive slots", "SELECT count(*) AS slots FROM pgvigil.replication_latest WHERE kind = 'slot' AND NOT coalesce(active, true)", red=1)
d.stat("Replication checks", "SELECT count(*) AS checks FROM pgvigil.replication_checks", red=1)
d.bars("Lag by stream (bytes)", f"""
SELECT v.instance || ' ' || r.kind || ' ' || r.key AS stream, r.lag_bytes
  FROM pgvigil.replication_latest r JOIN {NAME} v USING (instance_id)
 WHERE r.lag_bytes IS NOT NULL ORDER BY r.lag_bytes DESC LIMIT 20""", unit="bytes", w=8, h=4)
d.table("Streams", f"""
SELECT v.instance_id, v.instance, r.kind, r.key, r.state, r.active, r.lag_bytes, round(r.lag_secs::numeric, 3) AS lag_secs,
       r.snapshot_at, r.detail::text AS detail
  FROM pgvigil.replication_latest r JOIN {NAME} v USING (instance_id) ORDER BY v.instance, r.kind, r.key""", h=10, overrides=link_to_instance())
d.table("Replication checks", f"""
SELECT v.instance_id, v.instance, c.check_name, c.object, c.value, c.unit, c.state, c.snapshot_at
  FROM pgvigil.replication_checks c JOIN {NAME} v USING (instance_id) ORDER BY v.instance, c.check_name""", w=12, overrides=link_to_instance())
d.table("Oldest xmin holders", f"""
SELECT v.instance_id, v.instance, h.holder, h.name, h.datname, h.xmin_age, h.catalog_xmin_age, h.active, h.since
  FROM pgvigil.vacuum_xmin_holders h JOIN {NAME} v USING (instance_id)
 ORDER BY greatest(coalesce(h.xmin_age, 0), coalesce(h.catalog_xmin_age, 0)) DESC LIMIT 50""", w=12, overrides=link_to_instance())
d.write("06-replication")

# 7. Jobs ----------------------------------------------------------------------------------------------------
d = Dash("pgvigil-jobs", "pgvigil / Jobs", "pg_cron and pgAgent jobs across the fleet: the last run, failures, runs over their average, missed schedules.", instance_var=False)
d.stat("Jobs", "SELECT count(*) AS jobs FROM pgvigil.job_report WHERE is_present")
d.stat("Failures (7 days)", "SELECT coalesce(sum(failures_7d), 0) AS failures FROM pgvigil.job_report", red=1)
d.stat("Failing now", "SELECT count(*) AS failing FROM pgvigil.job_report WHERE fail_streak > 0", red=1)
d.stat("Missed", "SELECT count(*) AS missed FROM pgvigil.job_report WHERE missed", red=1)
d.stat("Over their average", "SELECT count(*) AS slow FROM pgvigil.job_report WHERE over_average", red=1)
d.stat("Running now", "SELECT count(*) AS running FROM pgvigil.job_running")
d.table("Jobs", """
SELECT instance_id, instance, scheduler, job_name, schedule, datname, run_as, active, last_status, last_start, last_duration_secs,
       runs_7d, failures_7d, fail_streak, avg_7d_secs, max_7d_secs, over_average, missed, next_run, last_message
  FROM pgvigil.job_report WHERE is_present ORDER BY fail_streak DESC, failures_7d DESC, instance, job_name""", h=10, overrides=link_to_instance())
d.table("Failed runs in the range", f"""
SELECT v.instance_id, v.instance, f.scheduler, f.job_name, f.status, f.start_time, f.end_time, round(f.duration_secs::numeric, 1) AS duration_secs,
       f.return_message
  FROM pgvigil.job_failures f JOIN {NAME} v USING (instance_id)
 WHERE f.start_time BETWEEN {TF} AND {TT} ORDER BY f.start_time DESC""", h=8, overrides=link_to_instance())
d.table("Running now", f"""
SELECT v.instance_id, v.instance, r.scheduler, r.job_name, r.run_id, r.start_time, r.running_secs
  FROM pgvigil.job_running r JOIN {NAME} v USING (instance_id) ORDER BY r.running_secs DESC""", w=12, h=6, overrides=link_to_instance())
d.table("Job checks", f"""
SELECT v.instance_id, v.instance, c.severity, c.check_name, c.object, c.detail, c.at
  FROM pgvigil.job_report_checks c JOIN {NAME} v USING (instance_id) ORDER BY c.severity, v.instance""", w=12, h=6, overrides=link_to_instance())
d.write("07-jobs")

# 8. Storage -------------------------------------------------------------------------------------------------
d = Dash("pgvigil-storage", "pgvigil / Storage", "Volumes and their forecast, database and table growth, wraparound, the storage checks.")
d.table("Volumes (fleet) by days until full", """
SELECT instance_id, instance, platform, volume, kind, total_bytes, used_bytes, free_pct, capacity_bytes, headroom_pct, autoscaling, at_maximum,
       growth_7d_per_day, growth_30d_per_day, days_until_full
  FROM pgvigil.volume_forecast(NULL) ORDER BY days_until_full NULLS LAST, free_pct""", h=9, overrides=link_to_instance())
d.bars("Free space on this instance's volumes", f"""
SELECT mount_point, free_pct FROM pgvigil.disk_report WHERE instance_id = {I} ORDER BY free_pct""", unit="percent", w=8, h=8)
d.table("Database sizes and growth", f"""
SELECT datname, size_bytes, growth_7d_per_day, growth_30d_per_day, days_to_double, snapshot_at
  FROM pgvigil.database_growth({I}) ORDER BY size_bytes DESC""", w=16, h=8)
d.table("Fastest-growing tables (7 days)", f"""
SELECT datname, schema_name, table_name, total_bytes, growth_7d_per_day, days_to_double FROM pgvigil.table_growth({I}, 20)""", w=12, h=9)
d.table("Wraparound", f"""
SELECT datname, xid_age, xid_freeze_pct, mxid_age, mxid_freeze_pct, user_tables, over_vacuum, autovacuum_off, never_vacuumed, snapshot_at
  FROM pgvigil.vacuum_wraparound WHERE instance_id = {I} ORDER BY xid_age DESC""", w=12, h=9)
d.ts("Temp bytes per second", f"""
SELECT snapshot_at AS time, round(sum(temp_bytes)::numeric / max(interval_secs), 0) AS temp_bytes_s
  FROM {RATE_DB} WHERE interval_secs > 0 GROUP BY snapshot_at HAVING NOT bool_or(reset) ORDER BY 1""", unit="Bps", w=12, h=7)
d.table("Storage and table checks (fleet)", f"""
SELECT v.instance_id, v.instance, c.severity, c.check_name, c.object, c.detail, c.at
  FROM (SELECT * FROM pgvigil.storage_checks UNION ALL SELECT * FROM pgvigil.table_checks) c JOIN {NAME} v USING (instance_id)
 ORDER BY CASE c.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, v.instance""", w=12, h=7, overrides=link_to_instance())
d.write("08-storage")

# 9. DMS -----------------------------------------------------------------------------------------------------
d = Dash("pgvigil-dms", "pgvigil / DMS", "AWS DMS tasks that target a monitored instance: latency, the drain ETA, table states and the DMS checks.", instance_var=False)
d.stat("Tasks", "SELECT count(*) AS tasks FROM pgvigil.dms_drain")
d.stat("Tables failed or suspended", "SELECT coalesce(sum(failed + suspended), 0) AS tables FROM pgvigil.dms_drain", red=1)
d.stat("Spilling to disk", "SELECT count(*) FILTER (WHERE spilling) AS tasks FROM pgvigil.dms_drain", red=1)
d.stat("Worst target latency", "SELECT max(latency_target_s) AS latency FROM pgvigil.dms_drain", unit="s")
d.stat("DMS checks", "SELECT count(*) AS checks FROM pgvigil.dms_checks", red=1)
d.table("Tasks", f"""
SELECT v.instance_id, v.instance, t.task_id, t.status, t.migration_type, t.latency_source_s, t.latency_target_s, t.speed_x, t.eta_secs,
       t.rows_behind, t.eta_rows_secs, t.spilling, t.tables, t.validated, t.pending, t.never_validated, t.failed, t.suspended,
       t.pending_records, t.failed_records, t.snapshot_at
  FROM pgvigil.dms_drain t JOIN {NAME} v USING (instance_id) ORDER BY v.instance, t.task_id""", h=8, overrides=link_to_instance())
d.table("DMS checks", f"""
SELECT v.instance_id, v.instance, c.severity, c.check_name, c.object, c.detail, c.at
  FROM pgvigil.dms_checks c JOIN {NAME} v USING (instance_id)
 ORDER BY CASE c.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, v.instance""", h=8, overrides=link_to_instance())
d.write("09-dms")

# 10. Backups ------------------------------------------------------------------------------------------------
d = Dash("pgvigil-backups", "pgvigil / Backups", "WAL archiving and the platform's backups across the fleet.", instance_var=False)
d.stat("Archiver failing", "SELECT count(*) FILTER (WHERE archiver_failing) AS instances FROM pgvigil.backup_status", red=1)
d.stat("WAL waiting to archive", "SELECT count(*) FILTER (WHERE wal_waiting) AS instances FROM pgvigil.backup_status", red=1)
d.stat("Oldest restore point", "SELECT max(restorable_age_s) AS age FROM pgvigil.backup_status", unit="s")
d.stat("Backup checks", "SELECT count(*) AS checks FROM pgvigil.backup_checks", red=1)
d.table("Backup status", """
SELECT instance_id, instance, platform, archive_mode, archiving, archiver_failing, wal_waiting, archived_count, failed_count,
       last_archived_time, last_failed_time, archive_lag_bytes, archive_age_s, retention_days, latest_restorable_time, restorable_age_s,
       backup_window, newest_automated_at, newest_manual_at, newest_snapshot_at, automated_count, manual_count
  FROM pgvigil.backup_status ORDER BY archiver_failing DESC NULLS LAST, instance""", h=10, overrides=link_to_instance())
d.table("Backup checks", f"""
SELECT v.instance_id, v.instance, c.severity, c.check_name, c.object, c.detail, c.at
  FROM pgvigil.backup_checks c JOIN {NAME} v USING (instance_id)
 ORDER BY CASE c.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, v.instance""", w=12, overrides=link_to_instance())
d.table("Backup findings", f"""
SELECT v.instance_id, v.instance, f.severity, f.setting AS "check", f.value, f.detail, f.suggested
  FROM pgvigil.backup_findings f JOIN {NAME} v USING (instance_id) ORDER BY {SEV_ORDER}, v.instance""", w=12, overrides=link_to_instance())
d.write("10-backups")

# 11. Corruption ---------------------------------------------------------------------------------------------
d = Dash("pgvigil-corruption", "pgvigil / Corruption", "Checksums, the corruption events read from the server logs and the amcheck runs.", instance_var=False)
d.stat("Events (24 h)", "SELECT coalesce(sum(events_24h), 0) AS events FROM pgvigil.corruption_summary", red=1)
d.stat("Events (7 days)", "SELECT coalesce(sum(events_7d), 0) AS events FROM pgvigil.corruption_summary", red=1)
d.stat("amcheck: corrupt objects", "SELECT coalesce(sum(amcheck_corrupt), 0) AS corrupt FROM pgvigil.corruption_summary", red=1)
d.stat("Without data checksums", "SELECT count(*) FILTER (WHERE data_checksums IS DISTINCT FROM 'on') AS instances FROM pgvigil.corruption_summary")
d.table("Instances", """
SELECT instance_id, instance, platform, data_checksums, ignore_checksum_failure, zero_damaged_pages, events_24h, events_7d, last_event,
       amcheck_last_run, amcheck_checked, amcheck_corrupt, amcheck_skipped
  FROM pgvigil.corruption_summary ORDER BY events_7d DESC, amcheck_corrupt DESC, instance""", h=9, overrides=link_to_instance())
d.table("Events in the range", f"""
SELECT v.instance_id, v.instance, e.at, e.class, e.message, e.relation_path, e.datname, e.usename, e.statement, e.detail
  FROM pgvigil.corruption_events e JOIN {NAME} v USING (instance_id)
 WHERE e.at BETWEEN {TF} AND {TT} ORDER BY e.at DESC""", h=8, overrides=link_to_instance())
d.table("amcheck (latest runs)", f"""
SELECT v.instance_id, v.instance, a.datname, a.check_name, a.status, a.checked, a.total, a.corrupt, a.errors, a.note, a.duration_ms, a.snapshot_at
  FROM pgvigil.amcheck_latest a JOIN {NAME} v USING (instance_id) ORDER BY a.corrupt DESC, v.instance, a.datname""", w=12, overrides=link_to_instance())
d.table("Corruption findings", f"""
SELECT v.instance_id, v.instance, f.severity, f.setting AS "check", f.value, f.detail, f.suggested
  FROM pgvigil.corruption_findings f JOIN {NAME} v USING (instance_id) ORDER BY {SEV_ORDER}, v.instance""", w=12, overrides=link_to_instance())
d.write("11-corruption")

# 12. Waits --------------------------------------------------------------------------------------------------
d = Dash("pgvigil-waits", "pgvigil / Waits", "What the sessions wait on now, the lock tree at the range's end and the waits of the range's long statements.")
d.pie("Active sessions by wait (latest snapshot)", f"""
SELECT coalesce(wait_event_type || ':' || wait_event, 'CPU (no wait)') AS wait, count(*) AS sessions
  FROM pgvigil.activity_latest WHERE instance_id = {I} AND state = 'active' GROUP BY 1 ORDER BY 2 DESC""")
d.bars("Top waits of the range's long statements", f"""
SELECT coalesce(top_wait, 'CPU (no wait)') AS wait, sum(at_least_secs) AS secs
  FROM pgvigil.slow_in_window({I}, {TF}, {TT}, 5, 1000) GROUP BY 1 ORDER BY 2 DESC LIMIT 15""", unit="s", w=16)
d.table("Waits now (fleet, active sessions)", f"""
SELECT v.instance_id, v.instance, count(*) AS active, count(*) FILTER (WHERE a.wait_event_type IS NULL) AS on_cpu,
       count(*) FILTER (WHERE a.wait_event_type = 'Lock') AS lock, count(*) FILTER (WHERE a.wait_event_type = 'LWLock') AS lwlock,
       count(*) FILTER (WHERE a.wait_event_type = 'IO') AS io, count(*) FILTER (WHERE a.wait_event_type = 'Client') AS client,
       count(*) FILTER (WHERE a.wait_event_type IN ('IPC', 'Timeout', 'BufferPin', 'Extension')) AS other
  FROM pgvigil.activity_latest a JOIN {NAME} v USING (instance_id) WHERE a.state = 'active'
 GROUP BY v.instance_id, v.instance ORDER BY lock DESC, active DESC""", h=8,
        desc="Only Lock waits are blocking; LWLock, IO, IPC, Client, BufferPin and Timeout waits are not.", overrides=link_to_instance())
d.table("Lock tree at the range's end", f"""
SELECT snapshot_at, top_blocker, level, pid, blocked_by::text AS blocked_by, blocked, state, wait, xact_start, datname, usename, application_name
  FROM pgvigil.lock_tree({I}, {TT}) ORDER BY path""", h=8)
d.table("Long statements of the range with their top wait", f"""
SELECT first_seen, at_least_secs, pid, state, top_wait, was_blocked, was_blocker, datname, usename, query
  FROM pgvigil.slow_in_window({I}, {TF}, {TT}, 5, 100) ORDER BY at_least_secs DESC""", h=10)
d.ts("Deadlocks and recovery conflicts", f"""
SELECT snapshot_at AS time, sum(deadlocks) AS deadlocks, sum(conflicts) AS conflicts
  FROM {RATE_DB} WHERE interval_secs > 0 GROUP BY snapshot_at HAVING NOT bool_or(reset) ORDER BY 1""", w=24, h=6, bars=True)
d.write("12-waits")

# 13. Indexes ------------------------------------------------------------------------------------------------
d = Dash("pgvigil-indexes", "pgvigil / Indexes", "The index advisor's findings: invalid, unused, redundant and missing indexes, with the suggested action.")
d.stat("Warnings", f"SELECT count(*) AS warnings FROM pgvigil.index_findings WHERE instance_id = {I} AND severity = 'warning'", red=1)
d.stat("Info", f"SELECT count(*) AS info FROM pgvigil.index_findings WHERE instance_id = {I} AND severity = 'info'")
d.table("Findings on this instance", f"""
SELECT f.severity, f.setting AS rule, f.value AS "index", f.detail, f.suggested, f.at
  FROM pgvigil.index_findings f WHERE f.instance_id = {I} ORDER BY {SEV_ORDER}, f.setting, f.value""", h=10,
        desc="The suggested action is text only: a DROP is checked against replicas and rare jobs before it runs.")
d.table("Findings per instance (fleet)", f"""
SELECT v.instance_id, v.instance, count(*) AS findings, count(*) FILTER (WHERE f.severity = 'warning') AS warnings,
       string_agg(DISTINCT f.setting, ', ') AS rules
  FROM pgvigil.index_findings f JOIN {NAME} v USING (instance_id) GROUP BY v.instance_id, v.instance ORDER BY warnings DESC, findings DESC""",
        w=12, h=8, overrides=link_to_instance())
d.table("Statements with the most block IO", f"""
SELECT queryid, datname, calls, io_blks, hit_pct, round(blk_read_ms::numeric, 1) AS blk_read_ms, round(mean_exec_ms::numeric, 2) AS mean_ms, query
  FROM pgvigil.top_statements_by({I}, {TF}, {TT}, 'io', 20)""", w=12, h=8,
        desc="Candidates for an index: check one as a hypothetical index (hypopg) before a CREATE.")
d.write("13-indexes")
print("ok")
