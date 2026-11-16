#!/usr/bin/env bash
# Proof of TEXT-NOW (internal/web/textread.go): stored statement text follows the instance's query_text policy AT
# READ, not only at capture. The demo (12 PostgreSQL and 3 SQL Server instances, one day) is seeded into a scratch
# repository - its texts stored as under 'full' - and served by `pgvigil serve` under four configuration files in
# turn: query_text full, none, normalized, and a mixed one (demo-onprem-erp01 and demo-onprem-sql01 named in the file
# with query_text none and a dsn nothing listens on, every other instance full). Each serve is walked: every
# 'GET /api/...' route web.go registers, called for a PostgreSQL and a SQL Server demo instance with the seed's window
# (a route that answers 4xx for want of another parameter is listed as skipped), the fleet routes without an
# instance, and the detail reads whose keys come from the list replies (a Query Store query and its .sqlplan, a
# deadlock and its .xdl, a blocked-process head, a slow-event shape, a log group's rows, a plan and its suggestion).
# Every string of every JSON reply is compared with the statement texts the repository holds (the tables and columns
# of TestStoredTextTagged's storedText; a text of 24 characters or more with a space in it): a reply string that is
# a stored text, or the start of one, is that text shown.
# Needs go, psql, curl, python3, ss and a superuser connection without dbname.
#   PGVIGIL_ADMIN_DSN     the superuser connection (creates and drops the scratch database)
#   PGVIGIL_DEMO_WAIT_S   how long the seed may take (default 600)
# Expected (written before the first run):
#  F. full: the walk shows stored texts (decisive), and each stored-text site the seed fills is shown by some reply:
#     the sites shown are listed; a site the seed leaves empty is said as such (not decisive for that site).
#  N. none: no reply string, on any route, is a stored text or the start of one; the .sqlplan and .xdl downloads answer
#     404 with 'not shown: this instance's query_text policy is "none"'.
#  Z. normalized: no reply string is a stored text that holds a literal (a quoted string or a number), or the start of
#     one; at least one reply shows a statement with '?' in a literal's place (the normalized form is served, not NULL).
#  M. mixed: no reply string is a stored text of erp01 or sql01 (their own routes and the fleet's: Running, Slow
#     queries, Reports); the fleet routes still show a stored text of another instance (the rule places each row by
#     its own instance, it does not hide the fleet).
#  A. the alert sends (the lead's T1 red row): `pgvigil alerts` with a file-drop channel under full drops at least one
#     alert whose value or detail is a stored text (a head statement: decisive); under none no dropped file holds a
#     stored text or the start of one (the head statement cut to "(not shown: ...)").
#  Red on d04bc70a (rel-j15dl): N, Z, M and A (none) fail - the routes and the sends return the texts stored under full.
# The judge's two corrections after green run 1 (the expectations above unchanged): M - a route that ignores instance=
# (Running fleet, Alerts, the ack's open alerts) answers every instance's rows to a call naming erp01 or sql01, so a
# row that carries its instance_id is judged by that instance, as the fleet's rows are; Z - a text plan's figures
# (cost, rows, time) are not literals: a plan's literals are judged on its expression lines only (plans.Mask's exprKeys).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_textnow_$RANDOM"; SRV=""
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in go psql curl python3 ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
PORT=""
for _ in $(seq 1 20); do p=$((21000 + RANDOM % 9000)); if ! ss -ltnH "( sport = :$p )" | grep -q .; then PORT=$p; break; fi; done
[[ -n "$PORT" ]] || fail "no free port"

# the lead's file web.go changes only through the WIRING patch (the reply hook, query's marker, three inline reads):
# applied to this run's copy when the tree holds textread.go and web.go lacks the hook (a red tree has neither)
if [[ -f scripts/textnow-wiring.patch && -f internal/web/textread.go ]] && ! grep -q applyTextNow internal/web/web.go; then
  git apply scripts/textnow-wiring.patch 2>/dev/null || patch -p1 --no-backup-if-mismatch < scripts/textnow-wiring.patch >/dev/null || fail "the wiring patch does not apply"
  echo "the wiring patch applied (scripts/textnow-wiring.patch)"
fi
echo "== build pgvigil and seed the demo into $DB"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
T0=$SECONDS
timeout "${PGVIGIL_DEMO_WAIT_S:-600}" "$WORK/pgvigil" demo -dsn "$DSN" -days 1 > "$WORK/demo.log" 2>&1 || { tail -5 "$WORK/demo.log"; fail "the seed"; }
echo "seeded in $((SECONDS - T0)) s"
q() { psql "$DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
PGI=$(q "select instance_id from pgvigil.instances where name = 'demo-onprem-erp01'")
MSI=$(q "select instance_id from pgvigil.instances where name = 'demo-onprem-sql01'")
[[ -n "$PGI" && -n "$MSI" ]] || fail "the demo has no demo-onprem-erp01 or demo-onprem-sql01"

echo "== the stored texts (every site of TestStoredTextTagged's list the seed filled)"
python3 - "$WORK/sites.sql" <<'EOF'
import sys
sites = {"query_text": ["query"], "statement_text": ["query"], "log_events": ["statement", "detail"], "slow_events": ["statement"],
  "plans": ["query", "plan_text"], "vacuum_running": ["query"], "schema_ddl_log": ["statement"], "pgaudit_events": ["statement", "parameters"],
  "mssql_qs_query": ["query_text"], "mssql_qs_plan": ["plan_xml"], "mssql_pc_text": ["query"], "mssql_requests": ["statement"],
  "mssql_deadlocks": ["victim_statement", "graph"], "mssql_blocked_reports": ["blocking_statement", "blocked_statement", "report"],
  "mssql_slow_events": ["statement"], "mssql_attentions": ["statement"], "mssql_ag_events": ["statement"], "mssql_trace_events": ["statement"],
  "mssql_audit_events": ["statement"], "mssql_memory_grant_query": ["statement"], "mssql_running_plan": ["plan_xml"], "mssql_live_plan": ["plan_xml"],
  "mssql_statement_text": ["statement"]}
parts = []
for t, cols in sites.items():
    for c in cols:
        inst = "x.instance_id" if t not in ("query_text", "mssql_statement_text") else "NULL::int"
        where = " AND x.kind = 'deadlock'" if (t, c) == ("log_events", "detail") else ""
        parts.append(f"SELECT DISTINCT '{t}.{c}' AS site, {inst} AS instance_id, x.{c}::text AS t FROM pgvigil.{t} x "
                     f"WHERE to_regclass('pgvigil.{t}') IS NOT NULL AND length(x.{c}::text) >= 24 AND x.{c}::text ~ ' '{where}")
open(sys.argv[1], "w").write("\nUNION ALL\n".join(parts))
EOF
# a site whose table this tree lacks is left out by name (to_regclass cannot guard a column list): each read apart
: > "$WORK/texts.tsv"
while IFS= read -r part; do
  psql "$DSN" -XAtq -F $'\t' -c "COPY ($part) TO STDOUT" >> "$WORK/texts.tsv" 2>/dev/null || true
done < <(python3 -c "import sys; print(open(sys.argv[1]).read().replace('\nUNION ALL\n', '\n'))" "$WORK/sites.sql")
echo "stored texts: $(wc -l < "$WORK/texts.tsv") (site, instance, text)"
cut -f1 "$WORK/texts.tsv" | sort | uniq -c | sed 's/^/  /'

serve_with() {   # $1 = the config's name; the file is $WORK/$1.yaml
  [[ -n "$SRV" ]] && { kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; SRV=""; }
  "$WORK/pgvigil" serve -config "$WORK/$1.yaml" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve-$1.log" 2>&1 &
  SRV=$!
  for _ in $(seq 1 60); do curl -fsS "http://127.0.0.1:$PORT/api/instances" >/dev/null 2>&1 && return 0; kill -0 $SRV 2>/dev/null || break; sleep 1; done
  tail -5 "$WORK/serve-$1.log"; fail "serve under $1 did not answer"
}
cfg() {   # $1 name, $2 the file-level policy, $3 'mixed' to name erp01 and sql01 with none
  { echo "repository:"; echo "  dsn: \"$DSN\""; echo "query_text: $2"
    if [[ "${3:-}" == mixed ]]; then
      echo "instances:"
      echo "  - name: demo-onprem-erp01"; echo "    dsn: \"host=127.0.0.1 port=1 user=nobody dbname=nobody connect_timeout=1\""; echo "    query_text: none"
      echo "  - name: demo-onprem-sql01"; echo "    engine: sqlserver"; echo "    dsn: \"sqlserver://nobody@127.0.0.1:1?database=master&connection+timeout=1\""; echo "    query_text: none"
    fi; } > "$WORK/$1.yaml"
}
cfg full full; cfg none none; cfg normalized normalized; cfg mixed full mixed
FROM=$(date -u -d '-30 hours' +%Y-%m-%dT%H:%M:%SZ); TO=$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)
grep -oE '"GET /api/[^" ]+"' internal/web/web.go | tr -d '"' | sed 's/^GET //' | sort -u > "$WORK/routes.txt"
echo "routes: $(wc -l < "$WORK/routes.txt")"

walk() {   # $1 = the policy name: writes $WORK/walk-$1.json
  python3 - "$1" "http://127.0.0.1:$PORT" "$PGI" "$MSI" "$FROM" "$TO" "$WORK" <<'EOF'
import json, sys, urllib.request, urllib.parse, urllib.error
pol, base, pgi, msi, frm, to, work = sys.argv[1:8]
routes = [l.strip() for l in open(f"{work}/routes.txt") if l.strip() and "{" not in l]
out = {"calls": [], "skipped": [], "downloads": {}}
def get(path, params):
    url = base + path + "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            body = r.read()
            return r.status, body, r.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers.get("Content-Type", "")
    except Exception as e:
        return 0, str(e).encode(), ""
def strings(v, acc):
    if isinstance(v, str): acc.append(v)
    elif isinstance(v, dict):
        for x in v.values(): strings(x, acc)
    elif isinstance(v, list):
        for x in v: strings(x, acc)
    return acc
def call(path, params, who):
    st, body, ct = get(path, params)
    rec = {"path": path, "params": params, "who": who, "status": st}
    if st == 200 and "json" in ct:
        try:
            v = json.loads(body); rec["strings"] = strings(v, []); rec["json"] = v
        except ValueError:
            rec["strings"] = []
    elif st == 200:
        rec["strings"] = [body.decode("utf-8", "replace")]
    else:
        rec["error"] = body[:200].decode("utf-8", "replace")
    out["calls"].append(rec)
    return rec
win = {"from": frm, "to": to}
for p in routes:
    for who, inst in (("pg", pgi), ("ms", msi), ("fleet", None)):
        rec = call(p, {**win, "instance": inst}, who)
        if rec["status"] >= 400: out["skipped"].append(f"{p} [{who}] {rec['status']}")
def rows(rec, part):
    v = rec.get("json")
    t = v.get(part) if isinstance(v, dict) and part else v
    if isinstance(t, dict) and "columns" in t:
        return [dict(zip(t["columns"], r)) for r in t["rows"]]
    return []
def first(path, part, who, params=None):
    for rec in out["calls"]:
        if rec["path"] == path and rec["who"] == who and rec["status"] == 200 and (params is None or all(rec["params"].get(k) == v for k, v in params.items())):
            rs = rows(rec, part)
            if rs: return rs[0]
    return None
# the detail reads
qs = call("/api/mssql/querystore", {**win, "instance": msi, "view": "top"}, "ms")
r = first("/api/mssql/querystore", "top", "ms")
if r and r.get("query_id") and r.get("query_hash"):
    call("/api/mssql/querystore/query", {**win, "instance": msi, "db": r["database_name"], "query": r["query_id"], "hash": r["query_hash"]}, "ms")
    pr = first("/api/mssql/querystore/query", "plans", "ms")
    if pr and pr.get("plan_id"):
        st, body, _ = get("/api/mssql/querystore/plan.sqlplan", {"instance": msi, "db": r["database_name"], "plan": pr["plan_id"]})
        out["downloads"]["sqlplan"] = [st, body[:300].decode("utf-8", "replace")]
for view in ("regressed", "forced", "tuning"):
    call("/api/mssql/querystore", {**win, "instance": msi, "view": view}, "ms")
for part in ("deadlocks", "blocked", "slow", "attentions", "ag_events"):
    call("/api/mssql/xe", {**win, "instance": msi, "part": part}, "ms")
d = first("/api/mssql/xe", "deadlocks", "ms", {"part": "deadlocks"})
if d:
    call("/api/mssql/xe/deadlock", {"instance": msi, "at": d["event_at"], "key": d["event_key"]}, "ms")
    st, body, _ = get("/api/mssql/xe/deadlock.xdl", {"instance": msi, "at": d["event_at"], "key": d["event_key"]})
    out["downloads"]["xdl"] = [st, body[:300].decode("utf-8", "replace")]
b = first("/api/mssql/xe", "blocked", "ms", {"part": "blocked"})
if b: call("/api/mssql/xe/blocked", {**win, "instance": msi, "head": b.get("head_key")}, "ms")
s = first("/api/mssql/xe", "slow", "ms", {"part": "slow"})
if s: call("/api/mssql/xe/slow", {**win, "instance": msi, "shape": s.get("shape_key")}, "ms")
g = first("/api/logs/groups", None, "pg") or first("/api/logs/groups", "groups", "pg")
if g and g.get("group_key"): call("/api/logs/groups/rows", {**win, "instance": pgi, "group": g["group_key"]}, "pg")
pl = first("/api/plans", "plans", "pg")
if pl and pl.get("plan_id"):
    call("/api/plan", {"id": pl["plan_id"]}, "pg")
    call("/api/plans/suggest", {"id": pl["plan_id"]}, "pg")
for kind in ("deadlock", "auth_fail", "plan", "slow"):
    call("/api/logs", {**win, "instance": pgi, "kind": kind}, "pg")
for rep in ("deadlocks", "failed", "flushed", "audit", "queries"):
    call("/api/reports", {"report": rep, "days": 2, **win}, "fleet")
for g in ("text", "instance"):
    call("/api/slow/groups", {**win, "group": g}, "fleet")
call("/api/slow/events", {**win}, "fleet")
for rec in out["calls"]:
    # mixed keeps the replies of the calls naming erp01 or sql01 too: a fleet-wide route's rows are judged by their instance
    if rec["who"] != "fleet" and not (pol == "mixed" and rec["who"] in ("pg", "ms")): rec.pop("json", None)
json.dump(out, open(f"{work}/walk-{pol}.json", "w"))
print(f"{pol}: {len(out['calls'])} calls, {sum(1 for c in out['calls'] if c['status'] == 200)} answered 200, {len(out['skipped'])} skipped")
EOF
}

judge() {   # $1 = the policy name
  python3 - "$1" "$WORK" "$PGI" "$MSI" <<'EOF'
import json, re, sys, collections
pol, work, pgi, msi = sys.argv[1:5]
texts = []
for l in open(f"{work}/texts.tsv", encoding="utf-8", errors="replace"):
    p = l.rstrip("\n").split("\t", 2)
    if len(p) == 3: texts.append((p[0], "" if p[1] == "\\N" else p[1], p[2].replace("\\n", "\n").replace("\\t", "\t").replace("\\\\", "\\")))
by = collections.defaultdict(list)
for t in texts: by[t[2][:24]].append(t)
lit = re.compile(r"'[^']+'|(?<![\w$])\d+(?![\w])")
# a plan's expression keys (internal/plans/mask.go exprKeys): only these carry the statement's literals
ek = set(re.findall(r'"([A-Za-z -]+)": true', re.search(r"var exprKeys = map\[string\]bool\{(.*?)\n\}", open("internal/plans/mask.go").read(), re.S).group(1)))
def exprs(v, acc):
    if isinstance(v, dict):
        for k, x in v.items():
            if k in ek and isinstance(x, str): acc.append(x)
            else: exprs(x, acc)
    elif isinstance(v, list):
        for x in v: exprs(x, acc)
    return acc
def has_lit(site, t):
    if site == "plans.plan_text":
        try: t = "\n".join(exprs(json.loads(t), []))
        except ValueError:
            t = "\n".join(l.strip().split(": ", 1)[1] for l in t.split("\n") if l.strip().split(": ", 1)[0] in ek and ": " in l)
    return lit.search(t)
walk = json.load(open(f"{work}/walk-{pol}.json"))
def hits(s):
    if len(s) < 24: return []
    return [t for t in by.get(s[:24], []) if t[2].startswith(s) or s.startswith(t[2])]
def tables(v, acc):
    if isinstance(v, dict):
        if "columns" in v and "rows" in v: acc.append(v)
        else:
            for x in v.values(): tables(x, acc)
    elif isinstance(v, list):
        for x in v: tables(x, acc)
    return acc
def strs(v, acc):
    if isinstance(v, str): acc.append(v)
    elif isinstance(v, dict):
        for x in v.values(): strs(x, acc)
    elif isinstance(v, list):
        for x in v: strs(x, acc)
    return acc
shown, leaks, qmarks, placed = collections.Counter(), [], 0, 0
for c in walk["calls"]:
    ss = c.get("strings", [])
    if pol == "mixed" and c["who"] in ("pg", "ms") and "json" in c:
        # a fleet-wide route answers every instance's rows: a row of another instance is judged by its own instance
        other = collections.Counter()
        for t in tables(c["json"], []):
            if "instance_id" not in t["columns"]: continue
            ii = t["columns"].index("instance_id")
            for r in t["rows"]:
                if str(r[ii]) not in (pgi, msi): other.update(strs(r, []))
        kept = collections.Counter(ss) - other
        placed += sum(1 for s in other.elements() if hits(s))
        ss = list(kept.elements())
    for s in ss:
        if "?" in s and re.search(r"\b(SELECT|UPDATE|INSERT|DELETE)\b", s, re.I): qmarks += 1
        for site, inst, t in hits(s):
            shown[site] += 1
            # mixed: erp01's and sql01's own routes show no stored text at all; the fleet's rows are judged by their instance below
            if pol == "none" or (pol == "normalized" and has_lit(site, t)) or (pol == "mixed" and c["who"] in ("pg", "ms")):
                leaks.append(f"{c['path']} [{c['who']}] shows {site} of instance {inst or '?'}: {t[:80]!r}")
print(f"== {pol}: {sum(shown.values())} reply strings are stored texts; sites shown: {dict(shown)}")
print(f"   skipped (4xx): {len(walk['skipped'])}; downloads: {walk['downloads']}")
bad = sorted(set(leaks))
# every leaking route once, with its sites and how many strings (the whole list: the inventory the walk measured)
per = collections.defaultdict(lambda: [0, set()])
for l in bad:
    route, rest = l.split(" shows ", 1)
    per[route][0] += 1; per[route][1].add(rest.split(" of instance")[0])
for route in sorted(per): print(f"   LEAK {route}: {per[route][0]} strings, {', '.join(sorted(per[route][1]))}")
print("   example leaks: " + " | ".join(bad[:3]))
alert_hits = sum(1 for c in walk["calls"] if c["who"] == "alert" for s in c.get("strings", []) if hits(s))
if any(c["who"] == "alert" for c in walk["calls"]):
    print(f"   the alert sends: {alert_hits} dropped string(s) are stored texts")
if pol == "full":
    if not alert_hits: print("   the alert sends under full drop no stored text: A is NOT DECISIVE")
    sites = sorted(set(t[0] for t in texts))
    print("   sites the seed filled and no reply showed: " + ", ".join(s for s in sites if not shown[s]) or "none")
    sys.exit(0 if sum(shown.values()) else 1)
if pol == "none":
    for k, v in walk["downloads"].items():
        if v[0] != 404 or "not shown" not in v[1]: bad.append(f"download {k}: {v[0]} {v[1][:80]!r}")
if pol == "normalized" and qmarks == 0: bad.append("no reply shows a normalized statement ('?')")
if pol == "mixed":
    print(f"   rows of other instances in the replies to calls naming erp01 / sql01 (a fleet-wide route), judged as the fleet's: {placed} stored-text string(s)")
    # each fleet table row by its instance_id: a row of erp01 or sql01 shows no stored text, another's may
    others = 0
    for c in walk["calls"]:
        if c["who"] != "fleet" or "json" not in c: continue
        for t in tables(c["json"], []):
            if "instance_id" not in t["columns"]: continue
            ii = t["columns"].index("instance_id")
            for r in t["rows"]:
                mine = str(r[ii]) in (pgi, msi)
                for cell in r:
                    if isinstance(cell, str) and hits(cell):
                        if mine: bad.append(f"{c['path']} [fleet] row of instance {r[ii]} shows {hits(cell)[0][0]}: {cell[:80]!r}")
                        else: others += 1
    print(f"   fleet rows of other instances showing their stored text: {others}")
    if others == 0: bad.append("the fleet routes show no other instance's text (hidden for every instance?)")
print(f"   {pol}: {'PASS' if not bad else 'FAIL (' + str(len(bad)) + ')'}")
sys.exit(1 if bad else 0)
EOF
}

alerts_with() {   # $1 = the policy: one pass of `pgvigil alerts` with a file drop named for it; its files join the walk
  local d="$WORK/drop-$1"; mkdir -p "$d"
  { cat "$WORK/$1.yaml"; echo "alerts:"; echo "  - name: textnow_$1"; echo "    kind: file"; echo "    file:"; echo "      dir: $d"; } > "$WORK/$1-alerts.yaml"
  "$WORK/pgvigil" alerts -config "$WORK/$1-alerts.yaml" > "$WORK/alerts-$1.log" 2>&1 || { tail -5 "$WORK/alerts-$1.log"; fail "pgvigil alerts under $1"; }
  python3 - "$WORK/walk-$1.json" "$d" <<'PY'
import json, os, sys
w = json.load(open(sys.argv[1])); acc = []
def strings(v):
    if isinstance(v, str): acc.append(v)
    elif isinstance(v, dict): [strings(x) for x in v.values()]
    elif isinstance(v, list): [strings(x) for x in v]
files = sorted(os.listdir(sys.argv[2]))
for f in files: strings(json.load(open(os.path.join(sys.argv[2], f))))
w["calls"].append({"path": "pgvigil alerts (file drop)", "who": "alert", "status": 200, "params": {}, "strings": acc})
json.dump(w, open(sys.argv[1], "w"))
print(f"alerts under {os.path.basename(sys.argv[2])[5:]}: {len(files)} file(s) dropped")
PY
}

rc=0
for pol in full none normalized mixed; do
  serve_with "$pol"
  walk "$pol"
  [[ "$pol" == full || "$pol" == none ]] && alerts_with "$pol"
  judge "$pol" || rc=1
done
[[ $rc -eq 0 ]] && echo "PASS" || { echo "FAIL"; exit 1; }
