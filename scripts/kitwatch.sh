#!/usr/bin/env bash
# kitwatch.sh - KITWATCH: the community kits pgvigil runs (the First Responder Kit, DarlingData, sp_WhoIsActive) at
# the versions pgvigil was built against AND at their newest, each run THROUGH pgvigil (serve's Run path and form, the
# collector's sp_WhoIsActive call) on one SQL Server 2022 container in one prepared state (scripts/lib/kitsetup.sh),
# and every difference that matters to pgvigil's code or page reported (internal/community/kits, cmd/kitshape). Run by
# the weekly workflow .github/workflows/kitwatch.yml; on the box by hand while developing.
#
#   bash scripts/kitwatch.sh            two passes - the pinned kits, then the newest; the kit verdict is the newest
#                                       against this week's pinned pass, and the pinned pass against shapes.json is a
#                                       line of its own ('pgvigil or the environment changed': main, the driver, the
#                                       runner); the ported blocks (ports.json) against the newest files
#   bash scripts/kitwatch.sh -baseline  the pinned pass alone: writes shapes.json and ports.json (pinned) into the
#                                       output folder, the deny list run over both (commit them with the code change)
#
# Environment: PGVIGIL_ADMIN_DSN (required) a superuser of a PostgreSQL for the throwaway repository database (keyword
# form; the workflow's service container); KITWATCH_OUT the output folder (default .kitwatch, git-ignored);
# KITWATCH_PREV the previous run's report.json ('new since the last run'); MSSQL_IMAGE the SQL Server image (the
# workflow pins it by digest); GH_TOKEN the job's own token for GitHub's API and raw files (optional: unauthenticated
# reads are rate-limited on shared runners); PGVIGIL_SAMPLE_DENY more words no report may hold. Never `set -x`: the
# SA password and the repository's login live in the environment only.
#
# Exit: 0 every tool the same or DRIFT only (warnings); 1 a BREAK line; 2 a kit's install failed or a tool's run
# failed in the newest pass; 3 the job could not run (a fetch, docker, SQL Server, PostgreSQL, a build, a state the
# tools need not reached) - each with its reason in the report.
#
# Proof rows (the expected first; the KITWATCH design's last section):
#   KW-A two fresh containers at the pinned kits compared with each other - two -baseline runs into two output folders,
#        then `kitshape compare -want a/shapes.json -got b/shapes.json`: no line, the collector entry ok, the noise
#        proof; graded only with KW-B (and `KITWATCH_NEWEST=pinned`: both passes of one run the same, exit 0).
#   KW-B the pinned kits with run-time plants (KITWATCH_NEWEST=pinned KITWATCH_PLANT=<name>: sed on the second pass's
#        copy, the planted string asserted present): each flagged with its kind and class, exit 1 (the missing-state
#        plant: exit 3). In the table below now: wia-column (BREAK read by name), blitz-column (DRIFT column added),
#        column-swap (DRIFT reordered), pd-set (BREAK set removed), cache-retype (DRIFT type), decline-reword and
#        decline-throw (BREAK outcome), preset-rename (BREAK preset parameter removed), new-param (BREAK new form
#        parameter), help-layout (BREAK help), sibling-call (BREAK new hard sibling), port-edit (DRIFT list; once the
#        pinned ports.json is committed), missing-state (exit 3), cut-frk - each sed written against the pinned files.
#   KW-C a kit file cut at a GO (KITWATCH_PLANT=cut-frk): 'installed without' and the FRK tools missing, exit 2.
#   KW-D (a RUN) the newest kits: exit 0 or 1; three kits with URL, sha256 and version; 14 tool lines, the collector
#        line, every port line; deny 0.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
MODE=check
[[ ${1:-} == -baseline ]] && MODE=baseline
OUT=${KITWATCH_OUT:-$ROOT/.kitwatch}; mkdir -p "$OUT"; OUT=$(realpath "$OUT")
N=$RANDOM$RANDOM
WORK=$(mktemp -d)
CT=kitwatch-mssql-$N; REPO=kitwatch_repo_$N
SRV=""; MADE_CT=""; HOLD=(); KS_WHY=""

# ---- the URLs: every source in one block (a 404 or a refusal = exit 3 naming the URL) ------------------------------
FRK_REPO=BrentOzarULTD/SQL-Server-First-Responder-Kit; FRK_FILE=Install-All-Scripts.sql
FRK_PIN=20260708          # 8.34 (@VersionDate 20260702); newest = the latest release's tag
DD_REPO=erikdarlingdata/DarlingData; DD_FILE=Install-All/DarlingData.sql
DD_PIN=205fc5137eb0       # 2026-11-01 (@version_date 20261101); newest = the default branch's head
WIA_REPO=amachanic/sp_whoisactive; WIA_FILE=sp_WhoIsActive.sql
WIA_PIN=20260409          # v2200.20260409; newest = the latest release's tag
PM_REPO=erikdarlingdata/PerformanceMonitor
PM_PIN=65bdb5f946f7       # 3.12.0's XE sessions (ports only, nothing installed); newest = the default branch's head

envfail() {
  printf 'KITWATCH could not run: %s\n' "$1" > "$OUT/report.txt"
  printf '{"verdict": 3, "denied": 0, "lines": [], "could_not_run": %s}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" > "$OUT/report.json"
  echo "KITWATCH could not run: $1" >&2
  exit 3
}
fail() { envfail "$*"; }   # the setup library's failures are the environment's
cleanup() {
  local p
  for p in "${HOLD[@]}" "$SRV"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  [[ -n "$MADE_CT" ]] && docker rm -f -v "$CT" >/dev/null 2>&1 || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
[[ -n ${PGVIGIL_ADMIN_DSN:-} ]] || envfail "PGVIGIL_ADMIN_DSN (a PostgreSQL superuser, keyword form) is not set"
for t in docker psql curl python3 ss go sha256sum; do command -v $t >/dev/null || envfail "$t is not on this machine"; done
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 12000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  envfail "no free port"
}
pw() { echo "$1$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')!a1"; }
auth=(); [[ -n ${GH_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GH_TOKEN")
api() { curl -sf --retry 1 --max-time 30 "${auth[@]}" "https://api.github.com/repos/$1" || envfail "GitHub's API refused https://api.github.com/repos/$1"; }
raw() {   # raw <repo> <ref> <path> <file>
  curl -sf --retry 1 --max-time 120 "${auth[@]}" -o "$4" "https://raw.githubusercontent.com/$1/$2/$3" || envfail "fetch https://raw.githubusercontent.com/$1/$2/$3"
}
jget() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

# ---- the kits: the pinned refs and the newest ------------------------------------------------------------------------
FRK_NEW=$FRK_PIN; DD_NEW=$DD_PIN; WIA_NEW=$WIA_PIN; PM_NEW=$PM_PIN
if [[ $MODE == check && ${KITWATCH_NEWEST:-} != pinned ]]; then
  FRK_NEW=$(api "$FRK_REPO/releases/latest" | jget tag_name)
  DD_NEW=$(api "$DD_REPO/commits/main" | jget sha); DD_NEW=${DD_NEW:0:12}
  WIA_NEW=$(api "$WIA_REPO/releases/latest" | jget tag_name)
  PM_NEW=$(api "$PM_REPO/commits/main" | jget sha); PM_NEW=${PM_NEW:0:12}
fi
mkdir -p "$WORK/pinned" "$WORK/newest"
raw "$FRK_REPO" "$FRK_PIN" "$FRK_FILE" "$WORK/pinned/frk.sql"; raw "$DD_REPO" "$DD_PIN" "$DD_FILE" "$WORK/pinned/dd.sql"; raw "$WIA_REPO" "$WIA_PIN" "$WIA_FILE" "$WORK/pinned/wia.sql"
if [[ $MODE == check ]]; then
  raw "$FRK_REPO" "$FRK_NEW" "$FRK_FILE" "$WORK/newest/frk.sql"; raw "$DD_REPO" "$DD_NEW" "$DD_FILE" "$WORK/newest/dd.sql"; raw "$WIA_REPO" "$WIA_NEW" "$WIA_FILE" "$WORK/newest/wia.sql"
fi

# ---- KW-B / KW-C: a run-time plant on the pinned files (never a committed modified kit: sp_WhoIsActive is GPL-3.0) ---
plant() {   # plant <file> <sed expression> <string that must then be present>
  sed -i "$2" "$1"
  grep -qF -- "$3" "$1" || envfail "the plant $KITWATCH_PLANT changed nothing ($3 not in $(basename "$1")): the row cannot pass as SAME"
}
if [[ -n ${KITWATCH_PLANT:-} ]]; then
  P=$WORK/newest; [[ $MODE == check ]] || envfail "a plant runs in the check mode"
  case $KITWATCH_PLANT in
    wia-column)   plant "$P/wia.sql" 's/\btempdb_current\b/tempdb_current_kb/g' tempdb_current_kb ;;
    blitz-column) plant "$P/frk.sql" "/--TOURSTOP05--/{n;s/SELECT  \\[Priority\\] ,/SELECT  [Priority] , N'planted' AS KitwatchPlanted ,/}" "N'planted' AS KitwatchPlanted" ;;
    column-swap)  plant "$P/frk.sql" '/--TOURSTOP05--/,/FROM    #BlitzResults/{s/\[FindingsGroup\] ,$/@@FG@@/;s/\[Finding\] ,$/[FindingsGroup] ,/;s/@@FG@@/[Finding] , \/* kitwatch: swapped *\//}' 'kitwatch: swapped' ;;
    pd-set)       plant "$P/dd.sql" "s/THREADPOOL = N'No current THREADPOOL waits';/@pass = @pass; \\/* kitwatch: set dropped *\\//" 'kitwatch: set dropped' ;;
    cache-retype) plant "$P/frk.sql" '/CREATE TABLE ##BlitzCacheResults (/,/);/s/CheckID INT,$/CheckID BIGINT, \/* kitwatch: retyped *\//' 'kitwatch: retyped' ;;
    decline-reword) plant "$P/dd.sql" 's/Current user does not have EXECUTE permission on xp_readerrorlog, so/Current user lacks EXECUTE on xp_readerrorlog, so/' 'Current user lacks EXECUTE on xp_readerrorlog' ;;
    decline-throw) plant "$P/dd.sql" "s/RAISERROR(N'This will not run on Azure SQL DB because it''s horrible.', 11, 1) WITH NOWAIT;/THROW 50001, N'This will not run on Azure SQL DB because it''s horrible.', 1;/" "THROW 50001, N'This will not run on Azure SQL DB" ;;
    preset-rename) plant "$P/dd.sql" '/^    dbo\.sp_IndexCleanup$/,/^GO$/s/@database_name\b/@kitwatch_db_planted/g' '@kitwatch_db_planted' ;;
    new-param)    plant "$P/frk.sql" '/^ALTER PROCEDURE dbo\.sp_BlitzWho $/{n;s/@Help TINYINT = 0 ,/@Help TINYINT = 0 , @KitwatchPlanted INT = 0 ,/}' '@KitwatchPlanted INT = 0' ;;
    help-layout)  plant "$P/dd.sql" '/^    dbo\.sp_PressureDetector$/,/^ *description =$/s/^\( *\)description =$/\1explanation_planted =/' 'explanation_planted =' ;;
    sibling-call) plant "$P/dd.sql" "/^    dbo\\.sp_PressureDetector\$/,/@version_date = '20261101';/s/@version_date = '20261101';/&\\nEXECUTE (N'EXECUTE dbo.sp_BlitzWho @VersionCheckMode = 1;'); \\/* kitwatch: sibling call *\\//" 'kitwatch: sibling call' ;;
    missing-state|port-edit) ;;   # set further on: a MARK no tool holds (once the setup library is read), a port's file (once fetched)
    cut-frk)      head -c "$(( $(wc -c < "$P/frk.sql") / 2 ))" "$P/frk.sql" > "$P/frk.cut" && mv "$P/frk.cut" "$P/frk.sql"
                  printf '\nGO\n' >> "$P/frk.sql" ;;
    *)            envfail "unknown plant $KITWATCH_PLANT" ;;
  esac
fi

# ---- the binaries ----------------------------------------------------------------------------------------------------
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil >"$WORK/build.log" 2>&1 || envfail "go build ./cmd/pgvigil: $(tail -3 "$WORK/build.log")"
CGO_ENABLED=0 go build -o "$WORK/kitshape" ./cmd/kitshape >>"$WORK/build.log" 2>&1 || envfail "go build ./cmd/kitshape: $(tail -3 "$WORK/build.log")"
BIN=$WORK/pgvigil; KS=$WORK/kitshape
# the columns the collector reads from sp_WhoIsActive BY NAME (requestsWIA's w.<col>) and the parameters it passes
READ_BY_NAME=$(grep -oE '\bw\.[A-Za-z_]+' internal/mssql/requests.go | sed 's/^w\.//' | sort -u | paste -sd, -)
[[ -n $READ_BY_NAME ]] || envfail "no w.<column> in internal/mssql/requests.go: the collector entry's columns are unknown"
WIA_ARGS=$("$KS" args | python3 -c 'import json,sys,re; print(json.dumps({m[0]: m[1] for m in re.findall(r"(@\w+)\s*=\s*([^,]+)", sys.stdin.read())}))')

# ---- SQL Server: one container, one prepared state ----------------------------------------------------------------
. "$ROOT/scripts/lib/kitsetup.sh"
if [[ ${KITWATCH_PLANT:-} == missing-state ]]; then   # KW-B: a state the pinned pass never reaches (exit 3, not a change)
  for i in "${!KS_SQL_RUNS[@]}"; do
    if [[ ${KS_SQL_RUNS[$i]} == sp_LogHunter~* ]]; then KS_SQL_RUNS[$i]='sp_LogHunter~after~kitwatch: a state never made~~{}'; fi
  done
  [[ ${KS_SQL_RUNS[*]} == *'kitwatch: a state never made'* ]] || envfail "the plant missing-state changed nothing"
fi
ks_container
ks_sales

# ---- the repository and serve ------------------------------------------------------------------------------------------
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" >/dev/null || envfail "the repository database could not be made"
export KW_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
export KW_MS_R="sqlserver://pgvigil_read:$RPW@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
printf 'repository:\n  dsn: env:KW_REPO_DSN\ninstances:\n  - name: testsql01\n    engine: sqlserver\n    dsn: env:KW_MS_R\n' > "$WORK/cfg.yaml"
CFG=$WORK/cfg.yaml
"$BIN" migrate -config "$CFG" >"$WORK/migrate.log" 2>&1 || envfail "migrate: $(tail -3 "$WORK/migrate.log")"
"$BIN" collect -config "$CFG" -once mssql_instance >"$WORK/collect.log" 2>&1 || true
q() { psql "$KW_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
MSID=$(q "select instance_id from pgvigil.instances where name = 'testsql01'")
[[ -n $MSID ]] || envfail "testsql01 is not registered: $(tail -3 "$WORK/collect.log")"
UIPW=$(pw Ui)
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$CFG" kitwatch >/dev/null 2>&1 || envfail "user add"
JAR=$WORK/jar
serve_up() {   # a fresh serve for each pass (its tool checks are cached per instance)
  [[ -n $SRV ]] && { kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; }
  PORT=$(freeport); U="http://127.0.0.1:$PORT"
  "$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" >"$WORK/serve.log" 2>&1 & SRV=$!
  local n
  for n in $(seq 1 60); do curl -sf -o /dev/null "$U/" && break; kill -0 "$SRV" 2>/dev/null || envfail "serve died: $(tail -3 "$WORK/serve.log")"; [[ $n == 60 ]] && envfail "serve did not answer"; sleep 0.5; done
  curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"kitwatch\",\"password\":\"$UIPW\"}" "$U/api/login" >/dev/null
  [[ -n $(awk '$6 == "pgvigil_session" {print $7}' "$JAR") ]] || envfail "no session cookie from serve"
}
post() { curl -s --max-time 150 -o "$2" -w '%{http_code}' -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$1" "$U/api/$3"; }

# runtool <dir> <tool> <params json> [<label>]: the form and the run (exact types), a timeout tried once more; the
# run's file is <dir>/<label or tool>.run.json
runtool() {
  local d=$1 tool=$2 params=$3 name=${4:-$2} code
  code=$(post "{\"instance_id\":$MSID,\"tool\":\"$tool\",\"database\":\"\"}" "$d/$name.params.json" community/params) || true
  [[ $code == 200 ]] || printf '{"params": [], "left_out": [], "help_sets": [], "error": %s}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "form answered $code")" > "$d/$name.params.json"
  for try in 1 2; do
    code=$(post "{\"instance_id\":$MSID,\"tool\":\"$tool\",\"database\":\"\",\"params\":$params,\"timeout_secs\":60,\"exact_types\":true}" "$d/$name.run.json" community/run) || true
    [[ $code == 200 ]] || printf '{"runs": [{"outcome": "failed", "error": %s, "sets": []}]}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "the run answered $code")" > "$d/$name.run.json"
    grep -qiE '"error": ?"[^"]*(deadline exceeded|timeout)' "$d/$name.run.json" || break
  done
}

# allparams <tool>: every parameter of the installed procedure (name, type, output), tab-separated
allparams() { sq "SELECT p.name + CHAR(9) + TYPE_NAME(p.user_type_id) + CHAR(9) + CAST(p.is_output AS varchar(1)) FROM sys.parameters p WHERE p.object_id = OBJECT_ID(N'dbo.$1', N'P') ORDER BY p.parameter_id" || true; }

# entry <dir> <name> <tool> <kit> <version> <date> <sha> <read by name> <hard siblings> <presets json>: one kits.Run
entry() {
  allparams "$3" > "$1/$2.allparams.tsv"
  python3 - "$@" <<'PY'
import json, sys
d, name, tool, kit, ver, date, sha, rbn, sibs, presets = sys.argv[1:11]
run = json.load(open(f"{d}/{name}.run.json"))["runs"][0]
form = json.load(open(f"{d}/{name}.params.json"))
outcome = "declined" if run.get("declined") else run.get("outcome", "failed")
msg = run.get("error", "")
if outcome == "failed" and ("deadline exceeded" in msg.lower() or "timeout" in msg.lower()):
    outcome = "timeout"
sets = []
for s in run.get("sets") or []:
    st, nl = s.get("sql_types") or [], s.get("nullable") or []
    cols = []
    for i, c in enumerate(s["columns"]):
        col = {"name": c, "type": s["types"][i]}
        if i < len(st):
            col["sql_type"] = st[i]
        if i < len(nl) and nl[i] is not None:
            col["nullable"] = nl[i]
        cols.append(col)
    sets.append({"columns": cols, "truncated": bool(s.get("truncated"))})
allp = []
for line in open(f"{d}/{name}.allparams.tsv").read().splitlines():
    p = line.split("\t")
    if len(p) == 3:
        allp.append({"name": p[0], "type": p[1], "output": p[2] == "1"})
e = {"tool": name, "kit": kit, "version": ver, "version_date": date, "sha256": sha, "outcome": outcome, "message": msg[:500],
     "sets": sets, "at_set_cap": bool(run.get("at_set_cap")), "form_params": [p["name"] for p in form.get("params", [])],
     "all_params": allp, "described": sum(1 for p in form.get("params", []) if p.get("help")),
     "presets": sorted(json.loads(presets).keys()), "read_by_name": [x for x in rbn.split(",") if x],
     "hard_siblings": [x for x in sibs.split(",") if x]}
json.dump(e, open(f"{d}/{name}.entry.json", "w"))
PY
}

# kitof <tool>: its kit's name; kitver <kit>: the version and date read from an installed procedure's definition
kitof() { case $1 in sp_Blitz*) echo frk ;; sp_WhoIsActive*) echo wia ;; *) echo dd ;; esac; }
declare -A KV KD KSHA KURL
kitver() {   # kitver <key> <procedure> <pass label>
  ks_definition "$2" > "$WORK/def.$1.sql"
  local v
  v=$("$KS" version "$WORK/def.$1.sql" | cut -f2-)
  KV[$1]=${v%%$'\t'*}; KD[$1]=${v##*$'\t'}
  # the pinned kits' versions are known: one not read there is the read's fault, never a baseline (in the newest
  # pass a version that does not parse is a report line)
  if [[ $3 == pinned && ${KV[$1]} == - ]]; then
    envfail "the pinned $1 version was not read from $2's definition ($(wc -c < "$WORK/def.$1.sql") characters read)"
  fi
}

# pass <label> <files dir>: install the three kits (the second pass drops the first's), prepare the state, run every
# tool through pgvigil in the capture's order, the collector, the siblings and the declines; writes $WORK/run-<label>.json
pass() {
  local label=$1 src=$2 d=$WORK/$1 row tool ph mark nokit params rc k
  mkdir -p "$d"
  if [[ $label == newest ]]; then
    ks_drop_kits
    sq "DBCC FREEPROCCACHE WITH NO_INFOMSGS;" >/dev/null; sq "ALTER DATABASE Sales SET QUERY_STORE CLEAR;" >/dev/null
  fi
  local failed=""
  ks_install "$src/frk.sql" $KS_PROCS_FRK || failed+="frk: $KS_WHY; "
  ks_install "$src/dd.sql" $KS_PROCS_DARLING || failed+="dd: $KS_WHY; "
  ks_install "$src/wia.sql" $KS_PROCS_WIA || failed+="wia: $KS_WHY; "
  [[ $label == pinned && -n $failed ]] && envfail "the pinned kits did not install: $failed"
  ks_grant_kits
  KSHA[frk]=$(sha256sum < "$src/frk.sql" | cut -c1-64); KSHA[dd]=$(sha256sum < "$src/dd.sql" | cut -c1-64); KSHA[wia]=$(sha256sum < "$src/wia.sql" | cut -c1-64)
  if [[ $label == pinned ]]; then KURL[frk]="$FRK_REPO@$FRK_PIN"; KURL[dd]="$DD_REPO@$DD_PIN"; KURL[wia]="$WIA_REPO@$WIA_PIN"
  else KURL[frk]="$FRK_REPO@$FRK_NEW"; KURL[dd]="$DD_REPO@$DD_NEW"; KURL[wia]="$WIA_REPO@$WIA_NEW"; fi
  kitver frk sp_Blitz "$label"; kitver dd sp_PressureDetector "$label"; kitver wia sp_WhoIsActive "$label"
  # the page's advice call: its outcome is a tool line of its own (F3)
  local advice=done
  ks_keeper || advice="failed: $KS_WHY"
  ks_workload || envfail "state not reached ($label): $KS_WHY"
  serve_up
  curl -s -b "$JAR" -o "$d/tools.json" "$U/api/community?instance=$MSID"
  presets() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(next((t.get("preset") or {} for t in d.get("tools", []) if t["id"] == sys.argv[2]), {})))' "$d/tools.json" "$1"; }
  merged() { python3 -c 'import json,sys; p=json.loads(sys.argv[1]); p.update(json.loads(sys.argv[2])); print(json.dumps(p))' "$(presets "$1")" "$2"; }
  runphase() {
    for row in "${KS_SQL_RUNS[@]}"; do
      IFS='~' read -r tool ph mark nokit params <<<"$row"
      [[ $ph == "$1" ]] || continue
      runtool "$d" "$tool" "$(merged "$tool" "$params")"
      rc=0; ks_mark "$d/$tool.run.json" "$tool" "$mark" "$nokit" >"$d/$tool.mark" || rc=$?
      cat "$d/$tool.mark"
      # the state is the pinned pass's to prove: a missing subject there is the environment's (exit 3); in the
      # newest pass the rows are the kit's own (an if, not '&&': a false test as the loop's last command would make
      # runphase return 1, and set -e would end the script after the table's last row)
      if [[ $rc == 2 && $label == pinned ]]; then envfail "state not reached: $(cat "$d/$tool.mark")"; fi
    done
  }
  runphase before
  ks_chain_hold || envfail "state not reached ($label): $KS_WHY"
  runphase chain
  # the collector entry: sp_WhoIsActive with exactly the collector's parameters, and the collector itself
  runtool "$d" sp_WhoIsActive "$WIA_ARGS" "sp_WhoIsActive (collector)"
  "$BIN" collect -config "$CFG" -once mssql_requests >"$d/collector.log" 2>&1 || true
  ks_chain_release
  runphase after
  # the run's own status: collection_dates holds every collection's latest run (collection_log only the runs that
  # were not ok - pgvigil.log_collection, 0001)
  q "select coalesce((select status || chr(9) || coalesce(note, '') from pgvigil.collection_dates where instance_id = $MSID and collection = 'mssql_requests'), 'none' || chr(9))" > "$d/collector.tsv"
  # no row: the run ended before it could log one (a failed Detect, the instance row, the command itself) - its own
  # last lines are the note (the run's passwords taken out), and the line goes to the job log either way
  if [[ $(cut -f1 "$d/collector.tsv") == none ]]; then
    local why; why=$(tail -n 3 "$d/collector.log" | tr '\n\t' '  ')
    why=${why//"$RPW"/***}; why=${why//"$MSSQL_SA_PASSWORD"/***}
    printf 'none\tno collection_dates row; collect -once said: %s\n' "${why:-nothing}" > "$d/collector.tsv"
  fi
  echo "collector mssql_requests ($label): $(tr '\t' ' ' < "$d/collector.tsv")"
  # the siblings (F3): every other kit procedure revoked from the read login, the tool run with its form's defaults;
  # a tool that then fails is run again with one procedure revoked at a time (those its own definition names)
  local others p sibs
  others=$(sq "SELECT name FROM sys.procedures WHERE is_ms_shipped = 0 AND schema_id = 1 AND name LIKE N'sp[_]%' ORDER BY name")
  declare -A SIB=()
  for row in "${KS_SQL_RUNS[@]}"; do
    IFS='~' read -r tool _ _ _ _ <<<"$row"
    for p in $others; do [[ $p == "$tool" ]] || sq "REVOKE EXECUTE ON dbo.$p FROM pgvigil_read;" >/dev/null; done
    runtool "$d" "$tool" '{}' "$tool.revoked"
    ks_grant_kits
    if ! grep -qE '"outcome": ?"done"|"declined": ?true' "$d/$tool.revoked.run.json"; then
      local def; def=$(ks_definition "$tool")
      sibs=""
      for p in $others; do
        [[ $p != "$tool" ]] && grep -qi -- "$p" <<<"$def" || continue
        sq "REVOKE EXECUTE ON dbo.$p FROM pgvigil_read;" >/dev/null
        runtool "$d" "$tool" '{}' "$tool.no-$p"
        sq "GRANT EXECUTE ON dbo.$p TO pgvigil_read;" >/dev/null
        grep -qE '"outcome": ?"done"|"declined": ?true' "$d/$tool.no-$p.run.json" || sibs+="$p,"
      done
      SIB[$tool]=${sibs%,}
    fi
  done
  # the declines a container can reach (F3): each run through the Run path, its outcome 'declined' or not
  sq "REVOKE EXECUTE ON sys.xp_readerrorlog FROM pgvigil_read;" >/dev/null
  runtool "$d" sp_LogHunter '{}' "sp_LogHunter (decline: no EXECUTE on xp_readerrorlog)"
  sq "GRANT EXECUTE ON sys.xp_readerrorlog TO pgvigil_read;" >/dev/null
  runtool "$d" sp_HumanEventsBlockViewer '{"@session_name":"kitwatch_none"}' "sp_HumanEventsBlockViewer (decline: no such session)"
  runtool "$d" sp_IndexCleanup '{"@database_name":"kitwatch_none"}' "sp_IndexCleanup (decline: no valid database)"
  srcdefs
  # the entries
  for row in "${KS_SQL_RUNS[@]}"; do
    IFS='~' read -r tool _ _ _ _ <<<"$row"; k=$(kitof "$tool")
    entry "$d" "$tool" "$tool" "$k" "${KV[$k]}" "${KD[$k]}" "${KSHA[$k]}" "" "${SIB[$tool]:-}" "$(presets "$tool")"
  done
  entry "$d" "sp_WhoIsActive (collector)" sp_WhoIsActive wia "${KV[wia]}" "${KD[wia]}" "${KSHA[wia]}" "$READ_BY_NAME" "" '{}'
  for k in "sp_LogHunter (decline: no EXECUTE on xp_readerrorlog)" "sp_HumanEventsBlockViewer (decline: no such session)" "sp_IndexCleanup (decline: no valid database)"; do
    entry "$d" "$k" "${k%% *}" dd "${KV[dd]}" "${KD[dd]}" "${KSHA[dd]}" "" "" '{}'
  done
  # the collector, the advice call, the Azure-only declines' source (text, message number, severity), the installs
  ADVICE=$advice FAILED=$failed DEFS=$WORK python3 - "$d" "$label" <<'PY'
import json, os, re, sys
d, label = sys.argv[1], sys.argv[2]
st, _, note = open(f"{d}/collector.tsv").read().rstrip("\n").partition("\t")
extra = [{"tool": "mssql_requests (the collector)", "kit": "wia", "outcome": st, "message": note[:500], "sets": [], "described": 0},
         {"tool": "sp_HumanEvents (the page's advice call)", "kit": "dd", "outcome": "done" if os.environ["ADVICE"] == "done" else "failed",
          "message": os.environ["ADVICE"][:500], "sets": [], "described": 0}]
# q_community.go's declines a container cannot reach: present in the installed definition, raised as an error
azure = [("sp_LogHunter", "This will not run on Azure SQL DB"), ("sp_IndexCleanup", "@get_all_databases is not supported on Azure SQL Database"),
         ("sp_HealthParser", "This won't work in Azure"), ("sp_QuickieStore", "Not all Azure offerings are supported")]
for proc, text in azure:
    src = open(os.path.join(os.environ["DEFS"], f"def.src.{proc}.sql"), errors="replace").read() if os.path.exists(os.path.join(os.environ["DEFS"], f"def.src.{proc}.sql")) else ""
    # the message as the error carries it, or as the source's T-SQL literal writes it (each apostrophe doubled)
    i = src.find(text)
    if i < 0:
        i = src.find(text.replace("'", "''"))
    if i < 0:
        out = "absent"
    else:
        before, after = src[max(0, i - 300):i], src[i:i + 300]
        sev = re.search(r"['\"]\s*,\s*(\d+)\s*,", after)
        if re.search(r"THROW\s+5000[1-9]", before, re.I):
            out = "thrown as another message"
        elif "RAISERROR" in before.upper() and sev and int(sev.group(1)) >= 11:
            out = "raised"
        elif sev:
            out = f"raised at severity {sev.group(1)}"
        else:
            out = "present, not raised"
    extra.append({"tool": f"{proc} (decline source: {text[:40]})", "kit": "dd", "outcome": out, "sets": [], "described": 0})
json.dump(extra, open(f"{d}/extra.json", "w"))
PY
  K_FRK="${KURL[frk]}"$'\t'"${KSHA[frk]}"$'\t'"${KV[frk]}"$'\t'"${KD[frk]}" K_DD="${KURL[dd]}"$'\t'"${KSHA[dd]}"$'\t'"${KV[dd]}"$'\t'"${KD[dd]}" \
  K_WIA="${KURL[wia]}"$'\t'"${KSHA[wia]}"$'\t'"${KV[wia]}"$'\t'"${KD[wia]}" FAILED=$failed ENGINE=$MS_SERVER python3 - "$d" "$WORK/run-$label.json" <<'PY'
import glob, json, os, sys
d, out = sys.argv[1], sys.argv[2]
runs = [json.load(open(f)) for f in sorted(glob.glob(f"{d}/*.entry.json"))] + json.load(open(f"{d}/extra.json"))
kits = []
for k in ("frk", "dd", "wia"):
    url, sha, ver, date = (os.environ["K_" + k.upper()].split("\t") + ["", "", "", ""])[:4]
    kits.append({"kit": k, "url": url, "sha256": sha, "version": ver, "version_date": date})
json.dump({"engine": os.environ["ENGINE"], "kits": kits, "runs": runs, "install_failed": os.environ["FAILED"]}, open(out, "w"), indent=1)
print(f"pass {os.path.basename(out)}: {len(runs)} entries")
PY
}

# the Azure-only declines are read from the installed definitions (pass sets them before its entries)
srcdefs() { local p; for p in sp_LogHunter sp_IndexCleanup sp_HealthParser sp_QuickieStore; do ks_definition "$p" > "$WORK/def.src.$p.sql"; done; }

echo "--- the pinned kits: FRK $FRK_PIN, DarlingData $DD_PIN, sp_WhoIsActive $WIA_PIN"
pass pinned "$WORK/pinned"

if [[ $MODE == baseline ]]; then
  cp "$WORK/run-pinned.json" "$OUT/shapes.json"
  if [[ ! -f internal/community/kits/ports.json ]]; then
    "$KS" deny "$OUT/shapes.json" || envfail "the deny list hit the baseline (above): nothing to commit"
    echo "baseline: $OUT/shapes.json written (deny 0; no ports.json manifest in the tree yet) - commit it with the code change"
    exit 0
  fi
  cp internal/community/kits/ports.json "$OUT/ports.json"
  mkdir -p "$WORK/files"
  python3 - "$OUT/ports.json" <<'PY' > "$WORK/portfiles.tsv"
import json, sys
for p in json.load(open(sys.argv[1])):
    print(p["repo"] + "\t" + p["path"])
PY
  while IFS=$'\t' read -r repo path; do
    case $repo in "$FRK_REPO") ref=$FRK_PIN ;; "$DD_REPO") ref=$DD_PIN ;; "$WIA_REPO") ref=$WIA_PIN ;; "$PM_REPO") ref=$PM_PIN ;; *) envfail "ports.json names an unknown repository $repo" ;; esac
    mkdir -p "$WORK/files/$repo/$(dirname "$path")"; raw "$repo" "$ref" "$path" "$WORK/files/$repo/$path"
  done < "$WORK/portfiles.tsv"
  "$KS" pin -manifest "$OUT/ports.json" -dir "$WORK/files" || envfail "the ports could not be pinned"
  "$KS" deny "$OUT/shapes.json" "$OUT/ports.json" || envfail "the deny list hit the baseline (above): nothing to commit"
  echo "baseline: $OUT/shapes.json and $OUT/ports.json written (deny 0) - commit them with the code change"
  exit 0
fi

echo "--- the newest kits: FRK $FRK_NEW, DarlingData $DD_NEW, sp_WhoIsActive $WIA_NEW"
pass newest "$WORK/newest"

# ---- the report ----------------------------------------------------------------------------------------------------------
"$KS" compare -want "$WORK/run-pinned.json" -got "$WORK/run-newest.json" -out "$WORK/lines-kits.json" || envfail "kitshape compare (kits)"
LINES=$WORK/lines-kits.json
if [[ -f internal/community/kits/shapes.json ]]; then
  "$KS" compare -want internal/community/kits/shapes.json -got "$WORK/run-pinned.json" -label 'pinned vs shapes.json: pgvigil or the environment' -out "$WORK/lines-env.json" || envfail "kitshape compare (baseline)"
  LINES+=",$WORK/lines-env.json"
fi
if [[ -f internal/community/kits/ports.json ]]; then
  mkdir -p "$WORK/files"
  python3 -c 'import json,sys; [print(p["repo"] + "\t" + p["path"]) for p in json.load(open(sys.argv[1]))]' internal/community/kits/ports.json > "$WORK/portfiles.tsv"
  while IFS=$'\t' read -r repo path; do
    case $repo in "$FRK_REPO") ref=$FRK_NEW ;; "$DD_REPO") ref=$DD_NEW ;; "$WIA_REPO") ref=$WIA_NEW ;; "$PM_REPO") ref=$PM_NEW ;; *) continue ;; esac
    mkdir -p "$WORK/files/$repo/$(dirname "$path")"
    curl -sf --retry 1 --max-time 120 "${auth[@]}" -o "$WORK/files/$repo/$path" "https://raw.githubusercontent.com/$repo/$ref/$path" || true
  done < "$WORK/portfiles.tsv"
  if [[ ${KITWATCH_PLANT:-} == port-edit ]]; then   # KW-B: a ported list's block edited in the fetched file (DRIFT list)
    plant "$WORK/files/$DD_REPO/$DD_FILE" "/\\/\\*Disk\\*\\//,/N'RESMGR_THROTTLED'/s/N'PAGEIOLATCH_SH',/N'PAGEIOLATCH_SH', N'KITWATCH_PLANTED_WAIT',/" "N'KITWATCH_PLANTED_WAIT'"
  fi
  "$KS" ports -manifest internal/community/kits/ports.json -dir "$WORK/files" -out "$WORK/lines-ports.json" || envfail "kitshape ports"
  LINES+=",$WORK/lines-ports.json"
fi
rc=0
"$KS" report -lines "$LINES" ${KITWATCH_PREV:+-prev "$KITWATCH_PREV"} -out "$OUT/report.json" -text "$WORK/lines.txt" || rc=$?
[[ $rc -le 1 ]] || envfail "kitshape report"
# 2: a kit that did not install, or a tool that failed in the newest pass
python3 - "$WORK/run-newest.json" <<'PY' && rc=2 || true
import json, sys
r = json.load(open(sys.argv[1]))
sys.exit(0 if r.get("install_failed") or any(x["outcome"] == "failed" for x in r["runs"] if "(decline" not in x["tool"]) else 1)
PY
# the summary: the date, each kit pinned and newest, then the lines (the deny list ran over them in kitshape report)
python3 - "$WORK/run-pinned.json" "$WORK/run-newest.json" "$WORK/lines.txt" "$rc" > "$OUT/report.txt" <<'PY'
import datetime, json, sys
p, n = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
print(f"KITWATCH {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M} UTC on {n['engine']} - exit {sys.argv[4]}")
names = {"frk": "First Responder Kit", "dd": "DarlingData", "wia": "sp_WhoIsActive"}
for a, b in zip(p["kits"], n["kits"]):
    same = "same file" if a["sha256"] == b["sha256"] else ("same version, file changed" if a["version"] == b["version"] else "NEWER")
    print(f"  {names[a['kit']]}: pinned {a['version']} ({a['version_date']}, {a['url']}) / newest {b['version']} ({b['version_date']}, {b['url']}) - {same}")
if n.get("install_failed"):
    print(f"  INSTALL FAILED (newest): {n['install_failed']}")
print()
print(open(sys.argv[3]).read(), end="")
PY
"$KS" deny "$OUT/report.txt" >/dev/null || { printf 'KITWATCH: the report held a denied word and is withheld; see the run log.\n' > "$OUT/report.txt"; }
cat "$OUT/report.txt"
exit "$rc"
