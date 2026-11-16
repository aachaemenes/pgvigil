#!/usr/bin/env bash
# capture.sh - takes the real SQL Server plans the plan-warning rules are tested on (internal/plans/mssqlwarn.go,
# mssqlwarn_test.go) from a throwaway SQL Server 2022 container, and sp_BlitzCache 8.34's own reading of the same
# statements as the oracle the thresholds are compared with.
#
# One container (4 CPUs, 'max degree of parallelism' 2, 'cost threshold for parallelism' 5, LAST_QUERY_PLAN_STATS
# off, no global trace flag); the database warnlab and its workload from capture.sql (invented names only). Each case:
# its estimated plan (SET SHOWPLAN_XML), then the batch executed runs= times, then its cached plan
# (sys.dm_exec_text_query_plan, which still answers past 128 nesting levels) and its Query Store plan, both found by
# the QueryHash of the marked statement in the estimated plan. Then sp_BlitzCache @ExpertMode = 1 over warnlab, and in
# the same session the raw flag and number columns of ##BlitzCacheProcs' Statement rows (never its formatted output).
#
# Box only (docker, curl, python3, sha256sum). Nothing from a client; nothing here is part of a proof.
#   MSSQL_IMAGE      the SQL Server image (default: the pinned 2022-CU27-GDR2-ubuntu-22.04, 16.0.4315.2)
#   FRK_BLITZCACHE   a local copy of sp_BlitzCache.sql 8.34 (default: fetched at the First Responder Kit tag 20260708);
#                    either way its sha256 must be the 8.34 file's
# Writes captured/ beside this script (replaced whole): <case>.est.sqlplan, <case>.cache.sqlplan, <case>.qs.sqlplan,
# capture-meta.tsv (the server line and one line per case), blitzcache-8.34.tsv (the oracle, a case column first),
# spelling.tsv (each boolean attribute's spellings per plan source).
# Expected: 'server 16.0.4315.2 cpus 4 maxdop 2 ctp 5 lqps 0'; one 'case <name>: ...' line per case; 'oracle: <n>
# statement rows, <m> matched to a case'; the spelling lines; the last line 'capture: <cases> cases, est <a>, cache
# <b>, qs <c>'; exit 0. A case that cannot make its plan (a trial) says why on its line and the capture goes on.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/captured
IMG=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04}
FRK_TAG=20260708
FRK_SHA=aba9ed53aba3ebabac30b696deec97f83ab5aa84490173315d4a21db45762aac
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
WORK=$(mktemp -d)
CT=warnlab-$RANDOM$RANDOM
MADE=""
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  if [[ -n "$MADE" ]]; then docker rm -f -v "$CT" >/dev/null 2>&1 || true; fi
  rm -rf -- "${WORK:?}"
}
trap cleanup EXIT
for t in docker curl python3 sha256sum; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
echo "load at the start: $(cut -d' ' -f1-3 /proc/loadavg)"

# ---- sp_BlitzCache 8.34, by its sha256 ------------------------------------------------------------------------------
BC=$WORK/sp_BlitzCache.sql
if [[ -n "${FRK_BLITZCACHE:-}" ]]; then
  cp -- "$FRK_BLITZCACHE" "$BC"
else
  curl -sfL --retry 1 --max-time 120 -o "$BC" \
    "https://raw.githubusercontent.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/$FRK_TAG/sp_BlitzCache.sql" \
    || fail "sp_BlitzCache.sql was not fetched at tag $FRK_TAG"
fi
got=$(sha256sum < "$BC" | cut -c1-64)
[[ $got == "$FRK_SHA" ]] || fail "sp_BlitzCache.sql has sha256 $got, not the 8.34 file's $FRK_SHA"
echo "ok   sp_BlitzCache.sql 8.34 (tag $FRK_TAG, sha256 ${FRK_SHA:0:16}...)"

# ---- the cases, split from capture.sql ------------------------------------------------------------------------------
mkdir -p "$WORK/cases"
python3 -I - "$HERE/capture.sql" "$WORK/cases" <<'PY'
import os, re, sys
src, out = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().split("\n")
setup, cases, cur = [], [], None
for ln in lines:
    m = re.match(r"^--@case (\w+) runs=(\d+)(?: timeout=(\d+))?\s*$", ln)
    if m:
        cur = {"name": m.group(1), "runs": m.group(2), "to": m.group(3) or "120", "pre": [], "body": []}
        cases.append(cur)
        continue
    if cur is None:
        setup.append(ln)
    elif ln.startswith("--@pre "):
        cur["pre"].append(ln[len("--@pre "):])
    else:
        cur["body"].append(ln)
open(os.path.join(out, "setup.sql"), "w", encoding="utf-8").write("\n".join(setup) + "\nGO\n")
seen = set()
with open(os.path.join(out, "list"), "w", encoding="utf-8") as lst:
    for c in cases:
        n = c["name"]
        if n in seen:
            sys.exit("capture.sql names the case %s twice" % n)
        seen.add(n)
        body = "\n".join(c["body"]).strip()
        if ("/* case:%s */" % n) not in body:
            sys.exit("case %s: its batch holds no /* case:%s */ marker" % (n, n))
        open(os.path.join(out, n + ".pre.sql"), "w", encoding="utf-8").write("".join(p + "\nGO\n" for p in c["pre"]))
        open(os.path.join(out, n + ".sql"), "w", encoding="utf-8").write(body + "\nGO\n")
        lst.write("%s %s %s\n" % (n, c["runs"], c["to"]))
print("ok   capture.sql: %d cases" % len(cases))
PY

# ---- SQL Server 2022 ------------------------------------------------------------------------------------------------
MSSQL_SA_PASSWORD="Wl$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')!a1"
export MSSQL_SA_PASSWORD
MADE=1
docker run -d --name "$CT" --cpuset-cpus 0-3 --memory 6g -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e MSSQL_PID=Developer \
  -e MSSQL_MEMORY_LIMIT_MB=4096 "$IMG" >/dev/null || fail "docker run $IMG"
sqi() {   # sqi <database> <timeout s>: one session over stdin, its output on stdout (-y 0: long values whole; sqlcmd
          # refuses -h with -y 0, so each result keeps its header: a tabular read prefixes its lines and greps them)
  docker exec -i -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$CT" "$SQLCMD" -S localhost -C -b -I -U sa \
    -d "$1" -t "$2" -y 0 -i /dev/stdin
}
for _ in $(seq 1 90); do echo "SELECT 1;" | sqi master 10 > "$WORK/probe.out" 2>&1 && break; sleep 2; done
if ! echo "SELECT 1;" | sqi master 10 > "$WORK/probe.out" 2>&1; then
  echo "the last probe said: $(tr -d '\r' < "$WORK/probe.out" | head -3 | cut -c1-200)"
  echo "the container: $(docker inspect -f '{{.State.Status}} exit {{.State.ExitCode}}' "$CT" 2>&1)"
  docker logs --tail 15 "$CT" 2>&1 | cut -c1-200
  fail "the SQL Server does not answer"
fi
printf '%s\n' "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;" \
  "EXEC sp_configure 'max degree of parallelism', 2; EXEC sp_configure 'cost threshold for parallelism', 5; RECONFIGURE;" \
  | sqi master 60 > "$WORK/step.out" 2>&1 || fail "sp_configure: $(tr -d '\r' < "$WORK/step.out" | grep -m1 -E 'Msg|rror' | cut -c1-200)"
sqi master 600 < "$BC" > "$WORK/step.out" 2>&1 || fail "sp_BlitzCache.sql did not install: $(tr -d '\r' < "$WORK/step.out" | grep -m1 -A1 -E 'Msg|rror' | tr '\n' ' ' | cut -c1-240)"
sqi master 1800 < "$WORK/cases/setup.sql" > "$WORK/step.out" 2>&1 || fail "the setup of capture.sql failed: $(tr -d '\r' < "$WORK/step.out" | grep -m1 -A1 -E 'Msg|rror' | tr '\n' ' ' | cut -c1-240)"
echo "ok   the server set, sp_BlitzCache installed, warnlab built"
SERVER=$(printf '%s\n' "SET NOCOUNT ON; SELECT CONCAT('SRV ', CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)), ' ', (SELECT cpu_count FROM sys.dm_os_sys_info), ' ', (SELECT CAST(value AS varchar(10)) FROM sys.configurations WHERE name = 'max degree of parallelism'), ' ', (SELECT CAST(value AS varchar(10)) FROM sys.configurations WHERE name = 'cost threshold for parallelism'), ' ', (SELECT CAST(value AS varchar(10)) FROM warnlab.sys.database_scoped_configurations WHERE name = 'LAST_QUERY_PLAN_STATS'));" \
  | sqi master 60 | tr -d '\r' | sed -n 's/^SRV //p' | tail -1)
read -r MSV CPUS MAXDOP CTP LQPS <<< "$SERVER"
[[ $MSV == 16.* ]] || fail "the image is not SQL Server 2022 (ProductVersion '$MSV')"
TFS=$(printf '%s\n' "SET NOCOUNT ON; CREATE TABLE #wl_tf (TraceFlag int, Status int, Global int, Session int); INSERT #wl_tf EXEC (N'DBCC TRACESTATUS (-1) WITH NO_INFOMSGS'); SELECT CONCAT('TF ', TraceFlag) FROM #wl_tf;" \
  | sqi master 60 | tr -d '\r' | sed -n 's/^TF //p' | paste -sd, -)
echo "server $MSV cpus $CPUS maxdop $MAXDOP ctp $CTP lqps $LQPS global-flags ${TFS:-none}"
[[ -z "$TFS" ]] || fail "a global trace flag is on ($TFS): the oracle would read another plan"

# ---- the cases ------------------------------------------------------------------------------------------------------
rm -rf -- "${OUT:?}"
mkdir -p "$OUT"
printf 'server\t%s\tcpus=%s\tmaxdop=%s\tctp=%s\tlast_query_plan_stats=%s\timage=%s\n' "$MSV" "$CPUS" "$MAXDOP" "$CTP" "$LQPS" "$IMG" > "$OUT/capture-meta.tsv"
plan_of() {   # plan_of <raw output> <plan file> <case>: the ShowPlanXML document out of sqlcmd's output; prints its hash
  python3 -I - "$1" "$2" "$3" <<'PY'
import sys, xml.etree.ElementTree as ET
raw, dst, case = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(raw, encoding="utf-8", errors="replace").read()
a, b = text.find("<ShowPlanXML"), text.rfind("</ShowPlanXML>")
if a < 0 or b < 0:
    print("none"); sys.exit(0)
doc = text[a:b + len("</ShowPlanXML>")]
try:
    root = ET.fromstring(doc)
except ET.ParseError as e:
    print("unparsed:%s" % str(e).replace(" ", "_")); sys.exit(0)
open(dst, "w", encoding="utf-8").write(doc + "\n")
mark = "case:%s */" % case
stmts = [e for e in root.iter() if e.tag.split("}")[-1] in ("StmtSimple", "StmtCursor", "StmtCond", "StmtReceive", "StmtUseDb")]
h = "nohash"
for e in stmts:   # the LAST marked statement with its own QueryHash: a procedure's statement under its EXEC
    if mark in (e.get("StatementText") or "") and e.get("QueryHash"):
        h = e.get("QueryHash")
print("%s %d" % (h, len(stmts)))
PY
}
NCASE=0; NEST=0; NCACHE=0; NQS=0
while read -r name runs to; do
  NCASE=$((NCASE + 1))
  pre=$WORK/cases/$name.pre.sql; body=$WORK/cases/$name.sql
  { printf 'SET NOCOUNT ON;\nGO\n'; cat "$pre"; printf 'SET SHOWPLAN_XML ON;\nGO\n'; cat "$body"; } \
    | sqi warnlab "$to" > "$WORK/est.raw" 2>&1 || true
  read -r hash nstmt <<< "$(plan_of "$WORK/est.raw" "$OUT/$name.est.sqlplan" "$name")"
  if [[ $hash == none || $hash == unparsed:* ]]; then
    est="FAIL ($hash: $(tr -d '\r' < "$WORK/est.raw" | grep -m1 -E 'Msg|rror' | cut -c1-160))"; hash=nohash; nstmt=0
  else est=ok; NEST=$((NEST + 1)); fi
  ex=ok
  for ((i = 0; i < runs; i++)); do
    if ! { printf 'SET NOCOUNT ON;\nGO\n'; cat "$pre" "$body"; } | sqi warnlab "$to" > /dev/null 2> "$WORK/exec.err"; then
      ex="FAIL ($(tr -d '\r' < "$WORK/exec.err" | grep -m1 -E 'Msg|rror|imeout' | cut -c1-160))"; break
    fi
  done
  cache=none; qs=none
  if [[ $hash == 0x* ]]; then
    printf '%s\n' "SET NOCOUNT ON; SELECT TOP (1) tqp.query_plan FROM sys.dm_exec_query_stats AS qs CROSS APPLY sys.dm_exec_text_query_plan(qs.plan_handle, DEFAULT, DEFAULT) AS tqp WHERE qs.query_hash = $hash ORDER BY qs.last_execution_time DESC;" \
      | sqi warnlab 120 > "$WORK/cache.raw" 2>&1 || true
    read -r h2 _ <<< "$(plan_of "$WORK/cache.raw" "$OUT/$name.cache.sqlplan" "$name")"
    [[ $h2 == none || $h2 == unparsed:* ]] || { cache=ok; NCACHE=$((NCACHE + 1)); }
    printf '%s\n' "SET NOCOUNT ON; SELECT TOP (1) p.query_plan FROM sys.query_store_plan AS p JOIN sys.query_store_query AS q ON q.query_id = p.query_id WHERE q.query_hash = $hash ORDER BY p.last_execution_time DESC;" \
      | sqi warnlab 120 > "$WORK/qs.raw" 2>&1 || true
    read -r h3 _ <<< "$(plan_of "$WORK/qs.raw" "$OUT/$name.qs.sqlplan" "$name")"
    [[ $h3 == none || $h3 == unparsed:* ]] || { qs=ok; NQS=$((NQS + 1)); }
  fi
  ph=-
  if [[ $cache == none ]]; then   # by the batch's text: a cursor (its DMV hash is 0x0000000000000000), DDL, a recompiled plan
    fb=$(printf '%s\n' "SET NOCOUNT ON; SELECT TOP (1) CONCAT('FB ', CONVERT(varchar(200), qs.plan_handle, 1), ' ', CONVERT(varchar(20), qs.query_hash, 1)) FROM sys.dm_exec_query_stats AS qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st WHERE st.text LIKE N'%case' + N':$name */%' ORDER BY qs.last_execution_time DESC;" \
      | sqi warnlab 120 2>/dev/null | tr -d '\r' | sed -n 's/^FB //p' | head -1) || true
    if [[ -n "$fb" ]]; then
      ph=${fb%% *}; dh=${fb##* }
      printf '%s\n' "SET NOCOUNT ON; SELECT query_plan FROM sys.dm_exec_text_query_plan($ph, DEFAULT, DEFAULT);" \
        | sqi warnlab 120 > "$WORK/cache.raw" 2>&1 || true
      read -r h2 _ <<< "$(plan_of "$WORK/cache.raw" "$OUT/$name.cache.sqlplan" "$name")"
      [[ $h2 == none || $h2 == unparsed:* ]] || { cache="ok (by text)"; NCACHE=$((NCACHE + 1)); }
      [[ $hash == 0x* ]] || hash=$dh
    fi
  fi
  if [[ $qs == none ]]; then
    printf '%s\n' "SET NOCOUNT ON; SELECT TOP (1) p.query_plan FROM sys.query_store_plan AS p JOIN sys.query_store_query AS q ON q.query_id = p.query_id JOIN sys.query_store_query_text AS t ON t.query_text_id = q.query_text_id WHERE t.query_sql_text LIKE N'%case' + N':$name */%' ORDER BY p.last_execution_time DESC;" \
      | sqi warnlab 120 > "$WORK/qs.raw" 2>&1 || true
    read -r h3 _ <<< "$(plan_of "$WORK/qs.raw" "$OUT/$name.qs.sqlplan" "$name")"
    [[ $h3 == none || $h3 == unparsed:* ]] || { qs="ok (by text)"; NQS=$((NQS + 1)); }
  fi
  echo "case $name: est $est, statements $nstmt, hash $hash, handle ${ph:0:24}, exec $ex x$runs, cache $cache, qs $qs"
  printf 'case\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$hash" "$nstmt" "est=$est" "exec=$ex" "cache=$cache" "qs=$qs" "$ph" >> "$OUT/capture-meta.tsv"
done < "$WORK/cases/list"

# ---- the oracle: sp_BlitzCache 8.34 @ExpertMode = 1, its raw columns ------------------------------------------------
COLS="QueryHash PlanHandle StatementStartOffset StatementEndOffset QueryPlanCost ExecutionCount AverageCPU AverageReturnedRows AverageWrites AvgSpills CompileTime is_parallel compile_timeout busy_loops unparameterized_query missing_index_count is_cursor is_forward_only_cursor is_cursor_dynamic near_parallel plan_warnings implicit_conversions tvf_join is_forced_serial is_key_lookup_expensive key_lookup_cost is_remote_query_expensive remote_query_cost trace_flags_session function_count clr_function_count is_table_variable relop_warnings is_table_scan backwards_scan forced_index columnstore_row_mode is_computed_scalar is_sort_expensive sort_cost is_computed_filter index_ops index_dml table_dml low_cost_high_cpu stale_stats is_adaptive index_spool_cost index_spool_rows table_spool_cost table_spool_rows is_spool_expensive is_spool_more_rows is_table_spool_expensive is_table_spool_more_rows estimated_rows is_bad_estimate is_paul_white_electric is_row_goal is_big_spills is_mstvf is_nonsargable select_with_writes Warnings"
SEL=""
for c in $COLS; do
  case $c in
    QueryHash|PlanHandle) e="CONVERT(nvarchar(max), $c, 1)" ;;
    trace_flags_session|Warnings) e="REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), $c), CHAR(9), N' '), CHAR(10), N' '), CHAR(13), N' ')" ;;
    *) e="CONVERT(nvarchar(max), CAST($c AS decimal(38, 6)))" ;;
  esac
  SEL="$SEL${SEL:+, }ISNULL($e, N'')"
done
printf '%s\n' "SET NOCOUNT ON;" \
  "EXEC master.dbo.sp_BlitzCache @ExpertMode = 1, @Top = 1000, @DatabaseName = N'warnlab', @HideSummary = 1, @SortOrder = 'CPU';" \
  "IF OBJECT_ID(N'warnlab.dbo.bc_out') IS NOT NULL DROP TABLE warnlab.dbo.bc_out;" \
  "SELECT CONCAT(N'BC', NCHAR(9), CONCAT_WS(NCHAR(9), $SEL)) AS line INTO warnlab.dbo.bc_out FROM ##BlitzCacheProcs WHERE SPID = @@SPID AND (QueryType = N'Statement' OR QueryType LIKE N'Statement (parent%');" \
  | sqi master 1800 > "$WORK/bc.out" 2>&1 || fail "sp_BlitzCache: $(tr -d '\r' < "$WORK/bc.out" | grep -m1 -E 'Msg|rror' | cut -c1-200)"
printf '%s\n' "SET NOCOUNT ON; SELECT line FROM dbo.bc_out;" | sqi warnlab 120 | tr -d '\r' | sed -n 's/^BC\t//p' > "$WORK/bc.tsv"
python3 -I - "$OUT/capture-meta.tsv" "$WORK/bc.tsv" "$OUT/blitzcache-8.34.tsv" "$COLS" <<'PY'
import sys
meta, raw, dst, cols = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()
ZERO = "0X0000000000000000"
case_of, case_of_ph = {}, {}
for ln in open(meta, encoding="utf-8"):
    f = ln.rstrip("\n").split("\t")
    if f[0] != "case":
        continue
    if f[2].startswith("0x") and f[2].upper() != ZERO:
        case_of[f[2].upper()] = f[1]
    if len(f) > 8 and f[8].startswith("0x"):
        case_of_ph[f[8].upper()] = f[1]   # a cursor's rows carry a zero hash: by its plan handle
rows = [ln.rstrip("\n").split("\t") for ln in open(raw, encoding="utf-8") if ln.strip()]
matched = 0
with open(dst, "w", encoding="utf-8") as out:
    out.write("case\t" + "\t".join(cols) + "\n")
    for r in rows:
        if len(r) != len(cols):
            sys.exit("an oracle row has %d fields, not %d" % (len(r), len(cols)))
        c = case_of.get(r[0].upper()) or case_of_ph.get(r[1].upper(), "-")
        matched += c != "-"
        out.write(c + "\t" + "\t".join(r) + "\n")
print("oracle: %d statement rows, %d matched to a case" % (len(rows), matched))
PY

# ---- the spellings of the boolean attributes, per plan source -------------------------------------------------------
python3 -I - "$OUT" <<'PY'
import collections, glob, os, re, sys
out = sys.argv[1]
names = ("Lookup", "Parallel", "ForcedIndex", "ForceSeek", "ForceScan", "NoExpandHint", "Ordered", "IsClrFunction",
         "ComputedColumn", "IsAdaptive", "ForwardOnly", "Partitioned", "IsComputed", "Spill", "WithOrderedPrefetch",
         "WithUnorderedPrefetch", "Optimized")
seen = collections.defaultdict(collections.Counter)
for f in sorted(glob.glob(os.path.join(out, "*.sqlplan"))):
    src = f.rsplit(".", 2)[-2]
    for n, v in re.findall(r'\b(%s)="([^"]*)"' % "|".join(names), open(f, encoding="utf-8").read()):
        seen[(src, n)][v] += 1
with open(os.path.join(out, "spelling.tsv"), "w", encoding="utf-8") as o:
    o.write("source\tattribute\tvalue\tcount\n")
    for (src, n) in sorted(seen):
        for v, k in sorted(seen[(src, n)].items()):
            o.write("%s\t%s\t%s\t%d\n" % (src, n, v, k))
            print("spelling %s %s=%s x%d" % (src, n, v, k))
PY
echo "load at the end: $(cut -d' ' -f1-3 /proc/loadavg)"
echo "capture: $NCASE cases, est $NEST, cache $NCACHE, qs $NQS"
