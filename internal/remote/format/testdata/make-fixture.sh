#!/usr/bin/env bash
# Builds testdata/ok/: one bundle of a SQL Server instance named HOST\INST, made with gzip and sha256sum alone (no
# pgvigil code), so the format's reader is held to a bundle written by plain tools. Run it from this folder; the
# result is committed, so a test never runs it.
set -euo pipefail
cd "$(dirname "$0")"
D=ok/site1/coll1/HOST%5CINST/2026-11-16/0000000001-20261116T175500Z
rm -rf ok && mkdir -p "$D"
printf '%s\n' \
  '{"n":1,"at":"2026-11-16T17:51:00Z","rows":[{"session_id":52,"query_hash":-4617315517961717760,"queryid":9223372036854775807,"query":"5d41402abc4b2a76b9719d911017c592ae2fbd3c2f1ec2b6d0b1e3a8f0c4d9e1"},{"session_id":61,"query":null}]}' \
  '{"n":3,"at":"2026-11-16T17:52:00Z","rows":[{"session_id":52,"wait_type":"LCK_M_X"}]}' > "$D/mssql_activity.ndjson"
printf '%s\n' \
  '{"n":2,"at":"2026-11-16T17:51:30Z","rows":[{"group_name":"ag1","role":"PRIMARY"},{"group_name":"ag1","role":"SECONDARY"}]}' > "$D/mssql_ag.ndjson"
raw_a=$(stat -c %s "$D/mssql_activity.ndjson"); raw_g=$(stat -c %s "$D/mssql_ag.ndjson")
gzip -n -9 "$D/mssql_activity.ndjson" "$D/mssql_ag.ndjson"
( cd "$D" && sha256sum mssql_activity.ndjson.gz mssql_ag.ndjson.gz > SHA256SUMS )
sum() { sha256sum "$1" | cut -d' ' -f1; }
size() { stat -c %s "$1"; }
cat > "$D/manifest.json" <<JSON
{
  "format": 1,
  "pgvigil_version": "v0.4.0-dev",
  "schema_level": "0329_remote",
  "site": "site1",
  "collector": "coll1",
  "stream": "3f9c0a7e5b1d2c48",
  "seq": 1,
  "window_from": "2026-11-16T17:50:00Z",
  "window_to": "2026-11-16T17:55:00Z",
  "query_text": "hash",
  "instance": {"engine": "sqlserver", "name": "HOST\\\\INST", "platform": "onprem", "server_version": "16.0.4295.3", "version_num": 16, "is_replica": false, "tags": ["env:prod"]},
  "files": [
    {"view": "mssql_activity", "name": "mssql_activity.ndjson.gz", "batches": 2, "rows": 3, "bytes": $(size "$D/mssql_activity.ndjson.gz"), "raw_bytes": $raw_a, "sha256": "$(sum "$D/mssql_activity.ndjson.gz")"},
    {"view": "mssql_ag", "name": "mssql_ag.ndjson.gz", "batches": 1, "rows": 2, "bytes": $(size "$D/mssql_ag.ndjson.gz"), "raw_bytes": $raw_g, "sha256": "$(sum "$D/mssql_ag.ndjson.gz")"}
  ],
  "sums_sha256": "$(sum "$D/SHA256SUMS")",
  "reads": [
    {"collection": "mssql_activity", "status": "ran", "runs": 2, "interval_secs": 60},
    {"collection": "mssql_ag", "status": "failed", "runs": 2, "failed": 1, "interval_secs": 120},
    {"collection": "mssql_jobs", "status": "skipped", "reason": "not_due"}
  ],
  "runs": [
    {"collection": "mssql_activity", "at": "2026-11-16T17:51:00Z", "ms": 120, "status": "ok"},
    {"collection": "mssql_ag", "at": "2026-11-16T17:51:30Z", "ms": 80, "status": "ok"},
    {"collection": "mssql_activity", "at": "2026-11-16T17:52:00Z", "ms": 110, "status": "ok"},
    {"collection": "mssql_ag", "at": "2026-11-16T17:53:30Z", "ms": 30000, "status": "error", "stage": "read", "note": "timeout after 30s"}
  ],
  "failures": [],
  "cursors": [
    {"source": "errorlog", "kind": "mssql", "file_name": "ERRORLOG", "file_offset": 4096, "last_event_at": "2026-11-16T17:52:10Z"},
    {"source": "jobs", "kind": "seq", "seq": 1234}
  ],
  "heartbeat": {"host": "jump01", "started": "2026-11-16T17:00:00Z", "at": "2026-11-16T17:55:00Z", "instances": 1, "fail_streak": 0}
}
JSON
