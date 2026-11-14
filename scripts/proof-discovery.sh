#!/usr/bin/env bash
# Proof of cloud discovery (task 205; task 103 part 2): the AWS, Azure and GCP labs read as proposals of Admin >
# Instances, each equal to a hand read of the cloud by its own CLI, and nothing created, changed or connected to in
# a lab (the hand read before and after the run is the same).
#
# Three stages:
#   scripts/proof-discovery.sh hand  <out>   (where the cloud CLIs are signed in: aws, az, gcloud; read-only calls)
#        writes the hand read: one line per server - aws|<key>|<engine>|<host>, azure|..., gcp|... - and one per
#        region or API the CLI could not read (aws-region-off|<region>, gcp-api-off|<api>)
#   scripts/proof-discovery.sh creds <out>   (the same machine) writes the box run's short-lived credentials, mode
#        0600: AWS keys from `aws configure export-credentials` (an hour), an Azure access token (an hour); GCP reads
#        with the box's own Compute Engine account (nothing of the signed-in user's leaves this machine)
#   scripts/proof-discovery.sh run           (the box) builds pgvigil, adds the three sources through the API (aws
#        through the page's form, clicked in a headless Chromium), and compares their proposals with the hand read
#        (PGVIGIL_DISCOVER_HAND, PGVIGIL_DISCOVER_CREDS)
#
# Expected (written before the first run, 2026-11-12 07:50 PST): AWS: the proposals are the hand read's (the lab's
# Aurora cluster: its writer endpoint; no reader endpoint while it has no reader); the regions the
# account has not enabled are the source's notes, as the CLI could not read them either. Azure: the lab
# subscription holds no SQL or PostgreSQL server: 0 proposals = 0 in the hand read,
# the Resource Graph call answered 200; NOT PROVEN live: the Resource Graph query's mapping of a real server (none
# in the lab: creating one is a new billed resource, the lab owner's word) - internal/discover's unit tests cover it on
# recorded answers. GCP: the lab project has neither the Cloud SQL Admin API nor the
# AlloyDB API enabled; the box's account lacks the cloud-platform scope: 0 proposals and the notes name the refusal
# of each API; NOT PROVEN live: a Cloud SQL or AlloyDB server (none in the lab: creating one is a new billed
# resource, the lab owner's word) - the mapping is proven by internal/discover's unit tests on recorded answers.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
STAGE=${1:-run}
AWS_PROFILE_LAB=${PGVIGIL_LAB_AWS_PROFILE:-}
AZ_SUB=${PGVIGIL_LAB_AZ_SUBSCRIPTION:-}
GCP_PROJECT=${PGVIGIL_LAB_GCP_PROJECT:-}
fail() { echo "FAIL: $*" >&2; exit 1; }
# the regions a source sweeps when it names none: the profile's own region and rds:DescribeSourceRegions there (the
# code names no region: the join's TestNoHardCodedAWSPartition), so the hand read covers the same
SEED=
if [[ -n "$AWS_PROFILE_LAB" ]]; then SEED=$(aws configure get region --profile "$AWS_PROFILE_LAB" 2>/dev/null || true); fi
regions() { { echo "$SEED"; aws rds describe-source-regions --profile "$AWS_PROFILE_LAB" --region "$SEED" --query 'SourceRegions[].RegionName' --output text | tr '\t' '\n'; } | grep . | sort -u; }

case "$STAGE" in
hand)
  OUT=${2:?hand <out>}; umask 077; : > "$OUT.tmp"
  [[ -n "$AWS_PROFILE_LAB" && -n "$AZ_SUB" && -n "$GCP_PROJECT" ]] || fail "hand: PGVIGIL_LAB_AWS_PROFILE, PGVIGIL_LAB_AZ_SUBSCRIPTION and PGVIGIL_LAB_GCP_PROJECT are required"
  # a mistyped id would make every later row compare against itself (an empty lab and its own 403 notes): refuse it here
  gcloud projects describe "$GCP_PROJECT" --format='value(projectId)' 2>/dev/null | grep -qxF "$GCP_PROJECT" || fail "hand: the GCP project $GCP_PROJECT is not one this gcloud sign-in can read"
  az account show --subscription "$AZ_SUB" --query id -o tsv 2>/dev/null | grep -qixF "$AZ_SUB" || fail "hand: the Azure subscription $AZ_SUB is not one this az sign-in can read"
  [[ -n "$SEED" ]] || fail "hand: the profile $AWS_PROFILE_LAB has no region (the sweep starts from it)"
  ACCT=$(aws sts get-caller-identity --profile "$AWS_PROFILE_LAB" --query Account --output text) || fail "hand: sts get-caller-identity"
  # the sweep's list as the code reads it (DescribeSourceRegions from the seed), said either way; then an independent
  # list (account list-regions, the enabled ones): a region it holds that the sweep's list lacks is read too
  if SRC=$(aws rds describe-source-regions --profile "$AWS_PROFILE_LAB" --region "$SEED" --query 'SourceRegions[].RegionName' --output text 2>"$OUT.err"); then
    LIST=$({ echo "$SEED"; tr '\t' '\n' <<<"$SRC"; } | grep . | sort -u); echo "aws-sweep|$(grep -c . <<<"$LIST")" >> "$OUT.tmp"
  else LIST=$SEED; echo "aws-sweep-refused|$(head -c 200 "$OUT.err" | tr '\n|' '  ')" >> "$OUT.tmp"; fi
  if ENABLED=$(aws account list-regions --profile "$AWS_PROFILE_LAB" --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT --query 'Regions[].RegionName' --output text 2>"$OUT.err"); then
    for r in $(tr '\t' '\n' <<<"$ENABLED" | grep . | sort -u); do grep -qxF "$r" <<<"$LIST" || echo "aws-region-unlisted|$r" >> "$OUT.tmp"; done
  else echo "aws-listregions-refused|$(head -c 200 "$OUT.err" | tr '\n|' '  ')" >> "$OUT.tmp"; fi
  # the regions the account has not enabled (D1's E10: noted 'not enabled for this account', never read), by the
  # account service, not by ec2:DescribeRegions (the call the code makes)
  if DIS=$(aws account list-regions --profile "$AWS_PROFILE_LAB" --region-opt-status-contains DISABLED --query 'Regions[].RegionName' --output text 2>"$OUT.err"); then
    for r in $(tr '\t' '\n' <<<"$DIS" | grep . | sort -u); do echo "aws-region-disabled|$r" >> "$OUT.tmp"; done
  fi
  for r in $(regions) $(grep '^aws-region-unlisted|' "$OUT.tmp" | cut -d'|' -f2); do
    grep -q "^aws-region-unlisted|$r$" "$OUT.tmp" || echo "aws-region|$r" >> "$OUT.tmp"
    if ! c=$(aws rds describe-db-clusters --profile "$AWS_PROFILE_LAB" --region "$r" --cli-connect-timeout 10 --output json 2>"$OUT.err"); then
      grep -qE 'InvalidClientTokenId|UnrecognizedClientException|AuthFailure|OptInRequired' "$OUT.err" && { echo "aws-region-off|$r" >> "$OUT.tmp"; continue; }
      grep -qE '\((AccessDenied|AccessDeniedException|UnauthorizedOperation)\)' "$OUT.err" && { echo "aws-region-denied|$r" >> "$OUT.tmp"; continue; }
      grep -qiE 'connect timeout|could not connect|name resolution' "$OUT.err" && { echo "aws-region-unreachable|$r" >> "$OUT.tmp"; continue; }
      fail "hand: aws $r: $(head -c 300 "$OUT.err")"
    fi
    i=$(aws rds describe-db-instances --profile "$AWS_PROFILE_LAB" --region "$r" --cli-connect-timeout 10 --output json) || fail "hand: aws instances $r"
    python3 - "$ACCT" "$r" "$c" "$i" >> "$OUT.tmp" <<'PY'
import json, re, sys
acct, r, c, i = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4])
RESERVED = {"tag", "cloud", "region", "account", "subscription", "resource-group", "project", "cluster", "role", "source-instance", "source-cluster"}
def eng(e):
    return "postgres" if e in ("postgres", "aurora-postgresql") else ("sqlserver" if e.startswith("sqlserver-") else "")
# one line per DB instance by its own endpoint: key, engine, host, resource id, role; then its serverless shape and its
# tag keys (the instance's and its cluster's), as the code reads them
roles, sv, ctags, masters = {}, {}, {}, {}
for x in c["DBClusters"]:
    if not eng(x["Engine"]):
        continue
    v = x.get("ServerlessV2ScalingConfiguration") or {}
    for m in x.get("DBClusterMembers", []):
        roles[m["DBInstanceIdentifier"]] = "writer" if m["IsClusterWriter"] else "reader"
        ctags[m["DBInstanceIdentifier"]] = {t["Key"]: t.get("Value", "") for t in x.get("TagList", [])}
        masters[m["DBInstanceIdentifier"]] = x.get("MasterUsername", "")
        if v:
            sv[m["DBInstanceIdentifier"]] = "%g to %g ACU%s" % (v.get("MinCapacity", 0), v.get("MaxCapacity", 0),
                                                              ", pauses after %d s idle" % v.get("SecondsUntilAutoPause", 0) if v.get("MinCapacity") == 0 else "")
for x in i["DBInstances"]:
    e = eng(x["Engine"])
    n = x["DBInstanceIdentifier"]
    if e and (x.get("Endpoint") or {}).get("Address"):
        role = roles.get(n) or ("replica" if x.get("ReadReplicaSourceDBInstanceIdentifier") else "")
        key = "aws:%s:%s:instance:%s" % (acct, r, n)
        print("aws|%s|%s|%s|%s|%s|%s|%s|%s" % (key, e, x["Endpoint"]["Address"], x["Endpoint"].get("Port", ""), x.get("DbiResourceId", ""), role,
                                              x.get("DBClusterIdentifier", ""), x.get("MasterUsername") or masters.get(n, "")))
        if x.get("DBInstanceClass") == "db.serverless":
            print("aws-serverless|%s|%s" % (key, sv.get(n, "")))
        # the keys as the code writes them (TagKey: lower-cased, other characters '-', 40 at most; 'tag' and pgvigil's
        # own keys left out), a key with an empty value marked
        tags = dict(ctags.get(n, {}), **{t["Key"]: t.get("Value", "") for t in x.get("TagList", [])})
        norm = {}
        for k, v in tags.items():
            nk = re.sub(r"[^a-z0-9_.-]+", "-", k.strip().lower()).strip("-")[:40]
            if nk and nk not in RESERVED:
                norm[nk] = norm.get(nk) or bool(str(v).strip())
        print("aws-tagkeys|%s|%s" % (key, ",".join(sorted(norm))))
        print("aws-tagkeys-valued|%s|%s" % (key, ",".join(sorted(k for k, has in norm.items() if has))))
PY
  done
  # Azure through Resource Manager's own lists (not Resource Graph, which the code reads)
  for t in Microsoft.Sql/servers/databases Microsoft.Sql/managedInstances Microsoft.DBforPostgreSQL/flexibleServers; do
    ids=$(az resource list --subscription "$AZ_SUB" --resource-type "$t" --query '[].id' -o tsv 2>"$OUT.err") || fail "hand: az $t: $(head -c 300 "$OUT.err")"
    while read -r id; do
      [[ -z "$id" || "${id,,}" == */databases/master ]] && continue
      lid=${id,,}
      sub=$(cut -d/ -f3 <<<"$lid")
      case "$t" in
        Microsoft.Sql/servers/databases) k="azure:$sub:sql:$(basename "${lid%%/databases/*}")/$(basename "$lid")" ;;
        Microsoft.Sql/managedInstances) k="azure:$sub:mi:$(basename "$lid")" ;;
        *) k="azure:$sub:pg:$(basename "$lid")" ;;
      esac
      echo "azure|$k" >> "$OUT.tmp"; done <<<"$ids"
  done
  for api in sql alloydb; do
    # a read pool (Cloud SQL's READ_POOL_INSTANCE, AlloyDB's READ_POOL) is a note in the code, never a proposal
    if [[ $api == sql ]]; then cmd=(gcloud sql instances list --project "$GCP_PROJECT" --format='value(name,databaseVersion,instanceType)' --quiet)
    else cmd=(gcloud alloydb instances list --project "$GCP_PROJECT" --cluster=- --region=- --format='value(name,instanceType)' --quiet); fi
    if out=$("${cmd[@]}" 2>"$OUT.err" </dev/null); then
      while read -r n v t; do [[ -z "$n" ]] && continue
        if [[ $api == sql ]]; then [[ ( "$v" == POSTGRES* || "$v" == SQLSERVER* ) && "$t" != READ_POOL_INSTANCE && "$t" != ON_PREMISES_INSTANCE ]] && echo "gcp|gcp:$GCP_PROJECT:sql:$n" >> "$OUT.tmp"
        else [[ "$v" == READ_POOL ]] || { IFS=/ read -r _ _ _ loc _ cl _ inst <<<"$n"; echo "gcp|gcp:$GCP_PROJECT:alloydb:$loc/$cl/$inst" >> "$OUT.tmp"; }; fi
      done <<<"$out"
    elif grep -qiE 'not enabled|has not been used|SERVICE_DISABLED|disabled' "$OUT.err"; then echo "gcp-api-off|$api" >> "$OUT.tmp"
    else fail "hand: gcloud $api: $(head -c 300 "$OUT.err")"; fi
  done
  rm -f "$OUT.err"; sort -u "$OUT.tmp" > "$OUT"; rm -f "$OUT.tmp"
  echo "hand: $(grep -c '^aws|' "$OUT" || true) aws, $(grep -c '^azure|' "$OUT" || true) azure, $(grep -c '^gcp|' "$OUT" || true) gcp server(s); AWS regions not enabled $(grep -c '^aws-region-off' "$OUT" || true), denied $(grep -c '^aws-region-denied' "$OUT" || true); GCP APIs off: $(grep '^gcp-api-off' "$OUT" | cut -d'|' -f2 | tr '\n' ' ')"
  exit 0 ;;
creds)
  OUT=${2:?creds <out>}; umask 077
  [[ -n "$AWS_PROFILE_LAB" && -n "$AZ_SUB" && -n "$GCP_PROJECT" ]] || fail "creds: PGVIGIL_LAB_AWS_PROFILE, PGVIGIL_LAB_AZ_SUBSCRIPTION and PGVIGIL_LAB_GCP_PROJECT are required"
  # a mistyped id would make every later row compare against itself (an empty lab and its own 403 notes): refuse it here
  gcloud projects describe "$GCP_PROJECT" --format='value(projectId)' 2>/dev/null | grep -qxF "$GCP_PROJECT" || fail "creds: the GCP project $GCP_PROJECT is not one this gcloud sign-in can read"
  az account show --subscription "$AZ_SUB" --query id -o tsv 2>/dev/null | grep -qixF "$AZ_SUB" || fail "creds: the Azure subscription $AZ_SUB is not one this az sign-in can read"
  [[ -n "$SEED" ]] || fail "creds: the profile $AWS_PROFILE_LAB has no region (the box's sweep starts from it)"
  trap 'rc=$?; [[ $rc == 0 ]] || rm -f "$OUT"' EXIT
  { aws configure export-credentials --profile "$AWS_PROFILE_LAB" --format env-no-export
    printf 'AZ_TOKEN=%s\n' "$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)"
    printf 'AZ_SUB=%s\nGCP_PROJECT=%s\n' "$AZ_SUB" "$GCP_PROJECT"
    printf 'AWS_REGION=%s\n' "$SEED"; } > "$OUT"  # the box's configuration region: the sweep starts from it
  chmod 600 "$OUT"; grep -q '^AWS_SESSION_TOKEN=' "$OUT" && grep -q '^AZ_TOKEN=.' "$OUT" || fail "creds: the AWS keys or the Azure token are missing"
  echo "creds: written to $OUT (mode 600; they expire within an hour)"; exit 0 ;;
run) ;;
*) fail "usage: proof-discovery.sh hand <out> | creds <out> | run" ;;
esac

# ---- run (the box) ----
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
HAND=${PGVIGIL_DISCOVER_HAND:?the hand read (stage hand)}; CREDS=${PGVIGIL_DISCOVER_CREDS:?the credentials file (stage creds)}
[[ -s "$HAND" && -s "$CREDS" ]] || fail "the hand read or the credentials file is empty"
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n'); PGDB=pgv_disc_$SUF; USR=proofdba$SUF
umask 077
TMPD=$(mktemp -d); SRVPID=; CHRPID=; SRV2PID=; STUBPID=; NPD5=
SHOTS=${PGVIGIL_SHOTS:-$TMPD/shots}; mkdir -p "$SHOTS"
UPW=$(printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')")
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  [[ -n "$SRV2PID" ]] && kill "$SRV2PID" 2>/dev/null || true
  [[ -n "$STUBPID" ]] && kill "$STUBPID" 2>/dev/null || true
  if [[ -n "$CHRPID" ]]; then kill "$CHRPID" 2>/dev/null || true; wait "$CHRPID" 2>/dev/null || true; fi
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in go psql curl python3 node npm chromium; do command -v "$t" >/dev/null || fail "needs $t"; done
# the credentials go to serve's environment only (never the build's, npm's or the browser's); the Azure token to the
# one API call that names it, as an environment variable (js reads @AZ_TOKEN), never on a command line
credval() { sed -n "s/^$1=//p" "$CREDS" | head -1; }
AZ_SUB=$(credval AZ_SUB); GCP_PROJECT=$(credval GCP_PROJECT)
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
js() { python3 -c 'import json, os, sys
d = {}
for a in sys.argv[1:]:
    k, v = a.split("=", 1)
    d[k] = os.environ[v[1:]] if v.startswith("@") else v
print(json.dumps(d))' "$@"; }
api() { local c; printf '%s' "$2" > "$TMPD/body.json"; c=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/body.json" "$U/api/$1"); cat "$TMPD/ans.json" >> "$TMPD/answers.log"; echo >> "$TMPD/answers.log"; echo "$c"; }

echo "== A. pgvigil (the wiring in the run's copy), the repository, serve =="
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git -cf - . | tar -C "$GSRC" -xf -
P=scripts/proof-instances-wiring.patch
if grep -q 'InstancesAdminView' "$GSRC/internal/web/web.go"; then echo "A: the tree holds the wiring"
elif [[ -f "$GSRC/$P" ]] && (cd "$GSRC" && patch -p1 --dry-run -s < "$P" >/dev/null); then (cd "$GSRC" && patch -p1 -s < "$P") && echo "A: $P applied to the run's copy"
else fail "A: the tree has no /api/admin/instances route and $P does not apply"; fi
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "A: the web build"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil" ./cmd/pgvigil) || fail "A: the build"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
CFGD=$TMPD/etc; mkdir -p "$CFGD"
printf 'repository:\n  dsn: "%s"\ninstances: []\n' "$PGDSN" > "$CFGD/pgvigil.yaml"
"$TMPD/pgvigil" migrate -config "$CFGD/pgvigil.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "A: migrate"; }
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$CFGD/pgvigil.yaml" "$USR" >/dev/null 2>&1 || fail "A: user add"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$PORT"
(set -a; . "$CREDS"; set +a; unset AZ_TOKEN; umask 022; exec "$TMPD/pgvigil" serve -config "$CFGD/pgvigil.yaml" -listen "127.0.0.1:$PORT") >"$TMPD/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.log" >&2; fail "A: serve exited"; }
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "A: the UI login"
echo "ok   A: serve on $PORT, a repository with no instance"

echo "== B. AWS through the page's form (headless Chromium) =="
CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu --window-size=1600,1200 about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
cat > "$TMPD/b.mjs" <<'JS'
const [port, U, shots] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const ready = async () => { for (let i = 0; i < 150; i++) { if (await ev(`!!document.querySelector('main .admin-instances h2')`)) { await sleep(400); return true; } await sleep(200); } return false; };
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
console.log(`login ${await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.B_USR)}, password: ${JSON.stringify(process.env.B_UPW)} }) }).then(r => r.status)`, true)}`);
// a hash change does not redraw the sign-in form: load the page anew with the session cookie (as proof-instances does)
await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
await cmd('Page.navigate', { url: U + '#/admin_instances' });
const isReady = await ready();
console.log(`ready ${isReady}`);
if (!isReady) { ws.close(); process.exit(3); }
const fill = (vals) => ev(`(() => { const f = [...document.querySelectorAll('main form')].find(f => f.getAttribute('aria-label') === 'Add a sync source');
  for (const [k, v] of Object.entries(${JSON.stringify(vals)})) { const c = f.querySelector('[name="' + k + '"]'); c.value = v; c.dispatchEvent(new Event('change')); } return true; })()`);
await fill({ kind: 'aws' });
console.log(`aws-fields-shown ${await ev(`!document.querySelector('[name=aws_regions]').closest('div').hidden && document.querySelector('[name=cms_host]').closest('div').hidden`)}`);
await fill({ name: 'aws1', aws_profile: '', aws_regions: '', every_min: '60' });
await ev(`[...document.querySelectorAll('main form')].find(f => f.getAttribute('aria-label') === 'Add a sync source').querySelector('button[type=submit]').click(); true`);
let s = '';
for (let i = 0; i < 600; i++) { await sleep(200); s = await ev(`document.querySelector('.admin-instances p[role=status]')?.textContent ?? ''`); if (!/^Working/.test(s)) break; }
console.log(`click "Add the source" (aws) -> ${JSON.stringify(s)}`);
console.log(`large-estate ${await ev(`document.querySelector('main').textContent.includes('a large estate may not finish')`)}`);
// the new controls (task 205): a click by aria-label, the status it left (or what it opened)
const press = async (label, settle = true) => {
  const ok = await ev(`(() => { const b = [...document.querySelectorAll('main button')].find(b => b.getAttribute('aria-label') === ${JSON.stringify(label)}); if (!b) return false; b.click(); return true; })()`);
  if (!ok) { console.log(`click ${JSON.stringify(label)} -> NOT FOUND`); return; }
  let t = '';
  for (let i = 0; i < 600 && settle; i++) { await sleep(200); t = await ev(`document.querySelector('.admin-instances p[role=status]')?.textContent ?? ''`); if (!/^Working/.test(t)) break; }
  await sleep(300);
  console.log(`click ${JSON.stringify(label)} -> ${JSON.stringify(settle ? t : 'opened')}`);
};
await press('Read the regions of aws1 again');
await press("Edit aws1's regions and cloud tags", false);
console.log(`edit-fields ${await ev(`!!document.querySelector('main input[name=regions]') && !!document.querySelector('main input[name=tag_keys]')`)}`);
await press('Cancel the edit of aws1', false); await sleep(1200);
console.log(`edit-cancelled ${await ev(`!document.querySelector('main input[name=regions]')`)}`);
const srv = await ev(`[...document.querySelectorAll('main button')].map(b => b.getAttribute('aria-label') ?? '').find(l => l.startsWith('Approve aws:')) ?? ''`);
await press(srv, false);
// the panel itself (the page's 'Add or edit an instance' form has a login field of its own): the span its Cancel is in
const panel = `[...document.querySelectorAll('main button')].find(b => b.getAttribute('aria-label') === ${JSON.stringify('Cancel the approve of ' + srv.slice('Approve '.length))})?.closest('span.actions')`;
console.log(`approve-panel ${await ev(`(() => { const p = ${panel}; return !!p && !!p.querySelector('input[name=login]') && [...p.querySelectorAll('button')].some(b => (b.getAttribute('aria-label') ?? '').startsWith('Test the connection to aws:')); })()`)}`);
await press(`Cancel the approve of ${srv.slice('Approve '.length)}`, false);
// Cancel redraws the page (a fetch): the panel gone and the proposal's Approve back, within 10 s
let back = false;
for (let i = 0; i < 50 && !back; i++) { back = await ev(`!${panel} && [...document.querySelectorAll('main button')].some(b => b.getAttribute('aria-label') === ${JSON.stringify(srv)})`); if (!back) await sleep(200); }
console.log(`approve-cancelled ${back}`);
for (const theme of ['light', 'dark']) {
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  await cmd('Page.navigate', { url: U + '#/admin_instances' }); await ready();
  const d = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); fs.writeFileSync(`${shots}/discovery-${theme}.png`, Buffer.from(d.result.data, 'base64'));
  console.log(`page ${theme} errors=${await ev(`document.querySelectorAll('main .error:not([role=status])').length`)}`);
}
ws.close(); process.exit(0);
JS
out=$(B_USR="$USR" B_UPW="$UPW" node "$TMPD/b.mjs" "$CDP" "$U/" "$SHOTS") || fail "B: the Chromium walk stopped: $out"
printf '%s\n' "$out" > "$TMPD/b.out"
echo "$out"
echo "$out" | grep -q '^login 200$' && echo "$out" | grep -q '^ready true$' && echo "$out" | grep -q '^aws-fields-shown true$' || fail "B: the page or the AWS fields"
echo "$out" | grep -q 'click "Add the source" (aws) -> "Source aws1 added and read' || fail "B: the AWS source through the page"
echo "$out" | grep -q '^large-estate true$' || fail "B: the form does not say a large estate's add read may not finish"
echo "$out" | grep -q 'click "Read the regions of aws1 again" -> "aws1: every region read again' || fail "B: Read the regions again"
echo "$out" | grep -q '^edit-fields true$' && echo "$out" | grep -q '^edit-cancelled true$' && echo "$out" | grep -q '^approve-panel true$' && echo "$out" | grep -q '^approve-cancelled true$' || fail "B: Edit, the approve panel or its Cancel"
! echo "$out" | grep -q 'NOT FOUND' || fail "B: a control was not found"
echo "$out" | grep -q '^page light errors=0$' && echo "$out" | grep -q '^page dark errors=0$' || fail "B: an error on the page"

echo "== C. Azure and GCP through the API =="
code=$(api admin/sources "$(AZ_TOKEN=$(credval AZ_TOKEN) js op=add kind=azure name=azure1 cloud_auth=token cloud_token=@AZ_TOKEN azure_subscriptions="$AZ_SUB" every_s=3600)")
[[ "$code" == 200 ]] || fail "C: the Azure source: $code $(head -c 400 "$TMPD/ans.json")"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if not d.get("sync_error") else 1)' "$TMPD/ans.json" || fail "C: the Azure read failed: $(head -c 400 "$TMPD/ans.json")"
code=$(api admin/sources "$(js op=add kind=gcp name=gcp1 cloud_auth=metadata gcp_projects="$GCP_PROJECT" every_s=3600)")
[[ "$code" == 200 ]] || fail "C: the GCP source: $code $(head -c 400 "$TMPD/ans.json")"
GCP_SYNC_ERR=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("sync_error") or "")' "$TMPD/ans.json")
echo "ok   C: azure1 (a token, subscription $AZ_SUB) and gcp1 (the box's account, project $GCP_PROJECT) added and read"

echo "== D. the proposals against the hand read =="
for c in aws azure gcp; do
  GOT=$(pq "SELECT '$c|' || server || CASE WHEN '$c' = 'aws' THEN '|' || engine || '|' || host || '|' || coalesce(port::text, '') || '|' || coalesce(resource_id, '') || '|'
              || coalesce((SELECT substr(t, 6) FROM unnest(tags) t WHERE t LIKE 'role:%' LIMIT 1), '') || '|'
              || coalesce((SELECT substr(t, 9) FROM unnest(tags) t WHERE t LIKE 'cluster:%' LIMIT 1), '') || '|' || coalesce(master_user, '') ELSE '' END
              FROM pgvigil.admin_proposals WHERE source = '${c}1' AND NOT gone ORDER BY 1" | sort)
  WANT=$(grep "^$c|" "$HAND" | sort || true)
  [[ "$GOT" == "$WANT" ]] || fail "D: $c: the proposals [$GOT] differ from the hand read [$WANT]"
  if [[ -z "$GOT" ]]; then echo "D: $c: 0 = 0 (an empty lab: the mapping is not proven live)"; else echo "D: $c: $(grep -c . <<<"$GOT") proposal(s) = the hand read: $(tr '\n' ' ' <<<"$GOT")"; fi
done
# the add's notes item by item (last_notes, the page's cell, stops before 4000 characters: a sweep of the partition
# notes 30+ regions)
NOTES_AWS=$(pq "SELECT coalesce(string_agg(x->>'text', '; ' ORDER BY o), '') FROM pgvigil.admin_sources s, jsonb_array_elements(s.note_items) WITH ORDINALITY AS t(x, o) WHERE s.name = 'aws1'")
[[ "$(pq "SELECT coalesce(length(last_notes), 0) <= 4000 FROM pgvigil.admin_sources WHERE name = 'aws1'")" == t ]] || fail "D: aws1's last_notes is over 4000 characters"
for r in $(grep '^aws-region-off|' "$HAND" | cut -d'|' -f2); do [[ "$NOTES_AWS" == *"$r: not enabled"* ]] || fail "D: aws: the region $r (off for the CLI) is not in the source's notes: $NOTES_AWS"; done
for r in $(grep '^aws-region-denied|' "$HAND" | cut -d'|' -f2); do [[ "$NOTES_AWS" == *"$r: not allowed for these credentials"* ]] || fail "D: aws: the region $r (denied to the CLI) is not in the source's notes: $NOTES_AWS"; done
# a region the CLI could not reach from the hand read's machine is not graded (the box's network may reach it): its
# answer here is printed; its servers, if any, still fail the proposals' equality above
UNREACH=$(grep '^aws-region-unreachable|' "$HAND" | cut -d'|' -f2 || true)
for r in $UNREACH; do echo "D: aws: $r: the CLI could not reach it (not graded); the source: $(grep -oE "(^|; )$r: [^;]*" <<<"$NOTES_AWS" | sed 's/^; //' || echo 'read, no note')"; done
BOXSILENT=$(grep -oE '(^|; )[a-z0-9-]+: not reachable' <<<"$NOTES_AWS" | sed 's/^; //' | cut -d: -f1 || true)
GOTREF=$(grep -oE '(^|; )[a-z0-9-]+: not (enabled|allowed)' <<<"$NOTES_AWS" | sed 's/^; //' | cut -d: -f1 | grep -vxF -e "${UNREACH:-^}" | sort || true)
WANTREF=$(grep -E '^aws-region-(off|denied)\|' "$HAND" | cut -d'|' -f2 | grep -vxF -e "${BOXSILENT:-^}" | sort || true)
[[ "$GOTREF" == "$WANTREF" ]] || fail "D: aws: the source refused other regions than the CLI: [$(tr '\n' ' ' <<<"$GOTREF")] vs [$(tr '\n' ' ' <<<"$WANTREF")]: $NOTES_AWS"
for r in $BOXSILENT; do grep -qxF "$r" <<<"$UNREACH" || echo "D: aws: $r did not answer the box within the call wait (the CLI got an answer): not graded"; done
[[ "$(pq "SELECT last_error IS NULL AND last_ok IS NOT NULL FROM pgvigil.admin_sources WHERE name = 'aws1'")" == t ]] || fail "D: aws: the read is not recorded as ok"
NOTES_GCP=$(pq "SELECT coalesce(last_notes, '') FROM pgvigil.admin_sources WHERE name = 'gcp1'")
for api in sql alloydb; do
  if grep -q "^gcp-api-off|$api$" "$HAND"; then
    what=$([[ $api == sql ]] && echo "Cloud SQL" || echo "AlloyDB")
    [[ "$NOTES_GCP" == *"$GCP_PROJECT $what: 403"* ]] || fail "D: gcp: the $what refusal is not in the notes: $NOTES_GCP"
  fi
done
# an API off (SERVICE_DISABLED) holds no server and counts as read; any other refusal leaves nothing read: the read fails
GOK=$(pq "SELECT (last_ok IS NOT NULL)::text || '|' || coalesce(last_error, '') FROM pgvigil.admin_sources WHERE name = 'gcp1'")
if [[ "$(grep -o 'SERVICE_DISABLED' <<<"$NOTES_GCP" | wc -l)" -ge 2 ]]; then
  [[ "$GOK" == "true|" && -z "$GCP_SYNC_ERR" ]] || fail "D: gcp: both APIs off reads as 0 servers, read ok; got [$GOK] [$GCP_SYNC_ERR]"
  echo "D: gcp: both APIs off (SERVICE_DISABLED): read ok, 0 servers"
else
  [[ "$GOK" == "false|"*"no project could be read"* && "$GCP_SYNC_ERR" == *"no project could be read"* ]] || fail "D: gcp: a refusal other than an API off must fail the read; got [$GOK] [$GCP_SYNC_ERR]"
  echo "D: gcp: the box's account was refused (not SERVICE_DISABLED): the read failed, nothing marked gone, the notes kept"
fi
echo "D: the notes: aws [$(cut -c1-200 <<<"$NOTES_AWS")...] gcp [$NOTES_GCP]"
echo "ok   D: aws, azure and gcp proposals equal the hand read (port, resource id, role, cluster, master user too; azure and gcp empty labs: not proven live); the regions and APIs the CLI could not read are the sources' notes; shots in $SHOTS (the credential scan is row F, after E)"

echo "== E. the design pass's rows (task 205) =="
# E1 (item 1): the add's read swept the partition from the configuration's region and kept the regions that answered;
# Read now reads those only (no refused region in its notes)
REG=$(pq "SELECT array_to_string(cloud_regions, ' ') FROM pgvigil.admin_sources WHERE name = 'aws1'")
# kept = the sweep's regions (RDS's list and, ec2:DescribeRegions answered, the enabled regions it lacks) less those
# refused (the CLI's off / denied) and those the account has not enabled (D1: never read); a region silent to the box
# stays (its servers unseen, never gone)
EXPECT=$(grep -E '^aws-region(-unlisted)?\|' "$HAND" | cut -d'|' -f2 | grep -vxF -f <(grep -E '^aws-region-(off|denied|disabled)\|' "$HAND" | cut -d'|' -f2; echo '^') | sort | tr '\n' ' ' | sed 's/ $//')
[[ "$(tr ' ' '\n' <<<"$REG" | sort | tr '\n' ' ' | sed 's/ $//')" == "$EXPECT" ]] || fail "E1: kept [$REG], want [$EXPECT] (the sweep's regions less the refused)"
if grep -q '^aws-sweep|' "$HAND"; then
  NS=$(grep '^aws-sweep|' "$HAND" | cut -d'|' -f2)
  [[ "$NOTES_AWS" == *"rds:DescribeSourceRegions in "*": $NS regions ("* ]] || fail "E1: the sweep's note does not say the CLI's $NS regions: $NOTES_AWS"
else [[ "$NOTES_AWS" == *"rds:DescribeSourceRegions not answered"* ]] || fail "E1: DescribeSourceRegions was refused to the CLI but the source does not say so"; fi
T2=$(pq "SELECT now()")
code=$(api admin/sources "$(js op=sync name=aws1)"); [[ "$code" == 200 ]] || fail "E1: Read now: $code $(head -c 300 "$TMPD/ans.json")"
N2=$(pq "SELECT coalesce(last_notes, '') FROM pgvigil.admin_sources WHERE name = 'aws1'")
# Read now asks the kept regions only: no sweep note, and no note of a region outside them is this read's (D4: a
# refused region keeps the sweep's note, with the sweep's time)
[[ "$N2" != *"DescribeSourceRegions"* ]] || fail "E1: Read now swept: $N2"
[[ "$(pq "SELECT count(*) FROM pgvigil.admin_sources s, jsonb_array_elements(s.note_items) x WHERE s.name = 'aws1' AND x->>'key' <> 'source' AND NOT x->>'key' = ANY (coalesce(s.cloud_regions, '{}')) AND (x->>'last')::timestamptz >= '$T2'::timestamptz")" == 0 ]] || fail "E1: Read now asked a region outside the kept ones: $N2"
ONE=""; [[ "$(wc -w <<<"$REG")" == 1 ]] && ONE=" (one readable region in the lab: 'kept what answered' and 'kept the seed' look the same here)"
echo "ok   E1: the sweep kept [$REG] = the sweep's regions less the refused (a silent one kept)$ONE; Read now read those only, no sweep (notes: [$N2])"
# E2 (c): one read of a source at a time: a claim held (as a read in flight holds it), Read now and a sweep are told;
# released, Read now reads
[[ -n "$(pq "SELECT pgvigil.import_admin_source_claim('aws1', 'proof-e2', 120, false)")" ]] || fail "E2: the claim was not taken"
for op in sync sweep; do code=$(api admin/sources "$(js op=$op name=aws1)")
  [[ "$code" == 409 && "$(cat "$TMPD/ans.json")" == *"a read of this source is running"* ]] || fail "E2: $op beside a read in flight: $code $(head -c 300 "$TMPD/ans.json")"; done
pq "SELECT pgvigil.import_admin_source_release('aws1', 'proof-e2')" >/dev/null
code=$(api admin/sources "$(js op=sync name=aws1)"); [[ "$code" == 200 ]] || fail "E2: Read now after the release: $code $(head -c 300 "$TMPD/ans.json")"
echo "ok   E2: with a read in flight, Read now and Read the regions again answered 409 'a read of this source is running'; released, Read now read (200)"
# E3 (c): a read that started before the last applied one is refused and changes nothing
B4=$(pq "SELECT string_agg(server || gone::text, ' ' ORDER BY server) FROM pgvigil.admin_proposals WHERE source = 'aws1'")
OLD=$(pq "SELECT pgvigil.import_admin_proposals('aws1', now(), '[]', NULL, '{}', now() - interval '1 day', 'proof', 'proof')->>'outcome'")
[[ "$OLD" == refused && "$(pq "SELECT string_agg(server || gone::text, ' ' ORDER BY server) FROM pgvigil.admin_proposals WHERE source = 'aws1'")" == "$B4" ]] || fail "E3: an older read was applied ($OLD)"
echo "ok   E3: an empty read that started a day before the last applied one was refused; no proposal marked gone"
# E4 (omission 2): one audit row per read: who, the counts, what was not seen
AUD=$(pq "SELECT count(*) FILTER (WHERE outcome = 'done' AND detail LIKE 'read %, new %, gone %, back %' AND ui_user = '$USR'), count(*) FILTER (WHERE outcome = 'refused'), count(*) FILTER (WHERE detail LIKE '%not seen: aws:%')
            FROM pgvigil.admin_audit WHERE op = 'source read' AND target = 'aws1'")
IFS='|' read -r AD AR AU <<<"$AUD"; WANT_AU=0; grep -qE '^aws-region-(off|denied|unreachable)\|' "$HAND" && WANT_AU=1
[[ "$AD" -ge 3 && "$AR" -ge 1 && "$AU" -ge "$WANT_AU" ]] || fail "E4: the read audit rows by $USR done|refused|with unseen = $AUD (want >=3|>=1|>=$WANT_AU)"
echo "ok   E4: aws1's reads audited: $AD done (counts), $AR refused (the older read), $AU naming what was not seen"
# E5 (D2, D1): no partition table: a region list naming another partition's region and a sovereign one is taken
# (the shape only); with ec2:DescribeRegions answered both are noted 'not a region of these credentials' partition
# (aws)', their servers unseen, never read; named by the admin they stay named and are noted at each read (only a
# sweep leaves such a region out); the lab region read. GovCloud / Azure Government / China not proven.
R1=$(cut -d' ' -f1 <<<"$REG")
code=$(api admin/sources "$(js op=add kind=aws name=aws3 aws_regions="$R1 us-gov-west-1 eusc-de-east-1" every_s=3600)")
[[ "$code" == 200 && "$(pq "SELECT count(*) FROM pgvigil.admin_sources WHERE name = 'aws3'")" == 1 ]] || fail "E5: an add naming us-gov-west-1 and eusc-de-east-1: $code $(head -c 300 "$TMPD/ans.json")"
N5=$(pq "SELECT coalesce(last_notes, '') FROM pgvigil.admin_sources WHERE name = 'aws3'")
for r in us-gov-west-1 eusc-de-east-1; do
  [[ "$N5" == *"$r: not a region of these credentials' partition (aws)"* ]] || fail "E5: $r is not noted as another partition's: $N5"; done
G5=$(pq "SELECT array_to_string(cloud_regions, E'\n') FROM pgvigil.admin_sources WHERE name = 'aws3'" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
W5=$(printf '%s\n' "$R1" us-gov-west-1 eusc-de-east-1 | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[[ "$G5" == "$W5" ]] || fail "E5: aws3 names [$G5], want the three as named [$W5]"
[[ "$N5" != *"$R1: "* ]] || fail "E5: the lab region $R1 was not read clean: $N5"
code=$(api admin/sources "$(js op=edit name=aws3 regions="$R1 us-gov-west-1")"); [[ "$code" == 200 ]] || fail "E5: an Edit naming us-gov-west-1: $code $(head -c 300 "$TMPD/ans.json")"
code=$(api admin/sources "$(js op=sync name=aws3)"); [[ "$code" == 200 ]] || fail "E5: Read now after the Edit: $code $(head -c 300 "$TMPD/ans.json")"
N5b=$(pq "SELECT coalesce(last_notes, '') FROM pgvigil.admin_sources WHERE name = 'aws3'")
[[ "$N5b" == *"us-gov-west-1: not a region of these credentials' partition (aws)"* && "$N5b" != *"eusc-de-east-1"* ]] || fail "E5: after the Edit and Read now: us-gov-west-1 noted again, eusc-de-east-1's note gone with it: $N5b"
! grep -q 'two AWS partitions' "$TMPD/answers.log" || fail "E5: an API answer still says 'two AWS partitions'"
code=$(api admin/sources "$(js op=remove name=aws3)"); [[ "$code" == 200 ]] || fail "E5: remove aws3: $code"
echo "ok   E5: an add naming $R1, us-gov-west-1 and eusc-de-east-1 accepted (200) and an Edit naming us-gov-west-1 too; both noted 'not a region of these credentials' partition (aws)' and never read, kept as named and noted again at the Read now after the Edit (eusc-de-east-1's note gone with the Edit), $R1 read; 'two AWS partitions' in no API answer; aws-us-gov / aws-cn / Azure usgov / Azure china: NOT PROVEN (no lab)"
# E6 (5 ii): cloud tags only by an allow-list; a reserved key refused
code=$(api admin/sources "$(js op=edit name=aws1 tag_keys=region)"); [[ "$code" != 200 && "$(cat "$TMPD/ans.json")" == *"not one of pgvigil"* ]] || fail "E6: a reserved key: $code $(head -c 300 "$TMPD/ans.json")"
HK=$(grep '^aws-tagkeys|' "$HAND" | cut -d'|' -f3 | tr ',' '\n' | grep . | sort -u | tr '\n' ' ' | sed 's/ $//')
HV=$(grep '^aws-tagkeys-valued|' "$HAND" | cut -d'|' -f3 | tr ',' '\n' | grep . | sort -u | head -1)
SK=$(pq "SELECT array_to_string(seen_tag_keys, ' ') FROM pgvigil.admin_sources WHERE name = 'aws1'")
[[ "$SK" == "$HK" ]] || fail "E6: the keys seen [$SK] differ from the hand read's [$HK]"
[[ "$(pq "SELECT count(*) FROM pgvigil.admin_proposals p, unnest(p.tags) t WHERE p.source = 'aws1' AND split_part(t, ':', 1) NOT IN ('cloud', 'region', 'account', 'cluster', 'role', 'source-instance', 'source-cluster')")" == 0 ]] || fail "E6: a resource tag came in with no allow-list"
if [[ -n "$HV" ]]; then K1=$HV; code=$(api admin/sources "$(js op=edit name=aws1 tag_keys="$K1")"); [[ "$code" == 200 ]] || fail "E6: edit tag keys: $code"
  code=$(api admin/sources "$(js op=sync name=aws1)"); [[ "$code" == 200 ]] || fail "E6: Read now: $code"
  [[ "$(pq "SELECT count(*) FROM pgvigil.admin_proposals p, unnest(p.tags) t WHERE p.source = 'aws1' AND t LIKE '$K1:%'")" -ge 1 ]] || fail "E6: the allowed key $K1 did not come in"
  echo "ok   E6: a reserved key refused; the keys seen = the hand read's [$HK]; none came in until '$K1' was allowed, then it did"
else echo "ok   E6: a reserved key refused; the keys seen = the hand read's [$HK]; the lab's instance carries no tag with a value: the allow-list's taking is proven by the unit tests only"; fi
# E7 (a, 5 i, omission 7, omission 10): the lab's writer instance: its own endpoint, role, no login; approve with its
# master user needs a tick, its auto-pause another; the instance's file asks TLS (serve only: nothing connects to the lab)
PID=$(pq "SELECT proposal_id FROM pgvigil.admin_proposals WHERE source = 'aws1' AND NOT gone ORDER BY server LIMIT 1")
PR=$(pq "SELECT server || '|' || coalesce(login, '') || '|' || coalesce(master_user, '') || '|' || coalesce(serverless, '') || '|' || auto_pause FROM pgvigil.admin_proposals WHERE proposal_id = $PID")
# auto_pause comes through the text concatenation as true / false (psql prints a boolean column as t / f)
IFS='|' read -r PK PL PM PS PA_ <<<"$PR"
[[ -z "$PL" && -n "$PM" ]] || fail "E7: the proposal carries a login or no master user: $PR"
HS=$(grep "^aws-serverless|$PK|" "$HAND" | cut -d'|' -f3 || true)
if [[ -n "$HS" ]]; then [[ "$PS" == *"$HS"* ]] || fail "E7: serverless [$PS] vs the hand read [$HS]"; fi
# the auto-pause from the hand read, not from pgvigil's own flag
if [[ "$HS" == *"pauses after"* ]]; then [[ "$PA_" == true ]] || fail "E7: the hand read says it pauses ($HS), the proposal's auto_pause is $PA_"; else [[ "$PA_" == false ]] || fail "E7: auto_pause $PA_ for a server the hand read says does not pause"; fi
code=$(api admin/proposals "$(js op=approve proposal_id="$PID" name=lab-writer login="$PM")"); [[ "$code" != 200 && "$(cat "$TMPD/ans.json")" == *"master user"* ]] || fail "E7: approve with the master user and no tick: $code $(head -c 300 "$TMPD/ans.json")"
STEP2=""
if [[ "$PA_" == true ]]; then
  code=$(api admin/proposals "{\"op\":\"approve\",\"proposal_id\":\"$PID\",\"name\":\"lab-writer\",\"login\":\"$PM\",\"confirm_master\":true}")
  [[ "$code" != 200 && "$(cat "$TMPD/ans.json")" == *"keeps it from pausing"* ]] || fail "E7: an auto-pausing server without its tick: $code $(head -c 300 "$TMPD/ans.json")"; STEP2="; the auto-pause asked its tick"
fi
code=$(api admin/proposals "{\"op\":\"approve\",\"proposal_id\":\"$PID\",\"name\":\"lab-writer\",\"login\":\"$PM\",\"confirm_master\":true,\"confirm_autopause\":true}")
[[ "$code" == 200 ]] || fail "E7: approve with the ticks: $code $(head -c 300 "$TMPD/ans.json")"
REF=$(pq "SELECT dsn_ref FROM pgvigil.admin_instances WHERE name = 'lab-writer'"); DSNF=${REF#file:}
grep -q 'sslmode=require' "$DSNF" && ! grep -q 'password=' "$DSNF" || fail "E7: the instance's file asks no TLS (or holds a password)"
[[ "$(pq "SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'proposal approve' AND outcome = 'done' AND detail LIKE '%through the master user $PM (ticked)%'")" == 1 ]] || fail "E7: the approve's audit row does not name the master user"
GS=$(curl -s -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/admin/instances" | python3 -c 'import json, sys; d = json.load(sys.stdin)["page"]; i = {c: n for n, c in enumerate(d["columns"])}; print([r[i["gone_source"]] for r in d["rows"] if r[i["name"]] == "lab-writer"][0])')
[[ "$GS" == None ]] || fail "E7: lab-writer says gone from $GS before its source lost it"
echo "ok   E7: $PK by its own endpoint (no login proposed, master user $PM shown; serverless [$PS]); the master user needed its tick$STEP2; approved with sslmode=require and no password; audited"
# E8 (omission 6): the same server from a second source needs a tick
code=$(api admin/sources "$(js op=add kind=aws name=aws2 aws_regions="$(cut -d: -f3 <<<"$PK")" every_s=3600)"); [[ "$code" == 200 ]] || fail "E8: aws2: $code $(head -c 300 "$TMPD/ans.json")"
P2=$(pq "SELECT proposal_id FROM pgvigil.admin_proposals WHERE source = 'aws2' AND server = '$PK'")
code=$(api admin/proposals "{\"op\":\"approve\",\"proposal_id\":\"$P2\",\"name\":\"lab-writer-2\",\"login\":\"pgvigil_monitor\",\"confirm_autopause\":true}")
[[ "$code" != 200 && "$(cat "$TMPD/ans.json")" == *"already an instance"* ]] || fail "E8: the same server twice: $code $(head -c 300 "$TMPD/ans.json")"
echo "ok   E8: aws2 (the region named, no sweep) proposes $PK again; its approve asks the tick: already an instance (reached by its host and port here; the resource-id branch is proven on a throwaway database, not on the box)"
# E9 (8 iii): the approved server gone from its source: its instance row says so (the read simulated: nothing deleted in the lab)
pq "SELECT pgvigil.import_admin_proposals('aws1', now(), '[]', NULL, '{}', now(), 'proof', 'proof')" >/dev/null
code=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/admin/instances"); [[ "$code" == 200 ]] || fail "E9: GET: $code"
python3 - "$TMPD/ans.json" <<'PY' || fail "E9: the gone line: $(head -c 300 "$TMPD/ans.json")"
import json, sys
d = json.load(open(sys.argv[1])); t = d["page"]; i = {c: n for n, c in enumerate(t["columns"])}
row = [r for r in t["rows"] if r[i["name"]] == "lab-writer"][0]
assert row[i["gone_source"]] == "aws1" and row[i["gone_since"]], row
print("E9: lab-writer: gone from %s since %s" % (row[i["gone_source"]], row[i["gone_since"]]))
PY
echo "ok   E9: an approved server its source no longer lists shows 'gone from aws1 since <t>'"
# E10 (D1, the region list granted): the source's notes carry no standing note; a region the account has not enabled
# (the account service's DISABLED list, the hand read) that the sweep met is noted 'not enabled for this account' with
# none of the token wording, never kept
[[ "$NOTES_AWS" != *"were not checked"* ]] || fail "E10: the add's read carries the standing note (ec2:DescribeRegions not answered?): $NOTES_AWS"
DISALL=$(grep '^aws-region-disabled|' "$HAND" | cut -d'|' -f2 | grep -xF -f <(grep '^aws-region|' "$HAND" | cut -d'|' -f2) || true)
DISW=$(head -1 <<<"$DISALL")
[[ -n "$DISW" ]] || fail "E10: the hand read has no DISABLED region inside the sweep's list (aws-region-disabled lines: $(grep -c '^aws-region-disabled|' "$HAND" || true))"
KEPT10=" $(pq "SELECT array_to_string(cloud_regions, ' ') FROM pgvigil.admin_sources WHERE name = 'aws1'") "
for r in $DISALL; do   # each one (the 12:27 amend: a silent opt-in region, me-south-1 on the box, is 'not enabled', never 'not reachable')
  [[ "$NOTES_AWS" == *"$r: not enabled for this account"* && "$NOTES_AWS" != *"$r: not enabled for these credentials, or not a region"* && "$NOTES_AWS" != *"$r: not reachable"* ]] || fail "E10: $r: $NOTES_AWS"
  [[ "$KEPT10" != *" $r "* ]] || fail "E10: $r was kept"; done
[[ "$N2" != *"were not checked"* ]] || fail "E10: E1's Read now carries the standing note: $N2"
echo "ok   E10: ec2:DescribeRegions answered: no standing note on the add's read or on E1's Read now; the $(wc -w <<<"$DISALL") DISABLED region(s) of the sweep's list (the account service's) each noted 'not enabled for this account', no token or 'not reachable' wording, not kept"
# E12 (D4): the hourly loop sweeps an AWS source whose regions are 7 days old, not one 6 days old (serve's loop ticks
# every 30 s; the source made due by its last run set back)
loopwait() { # $1 source, $2 the last_run before, $3 seconds: until the loop's read has run
  for _ in $(seq 1 "$3"); do [[ "$(pq "SELECT last_run > '$2'::timestamptz FROM pgvigil.admin_sources WHERE name = '$1'")" == t ]] && return 0; sleep 1; done
  fail "E12: the loop did not read $1 within $3 s"; }
# the regions and the last sweep tried (sweep_tried_at: the add's and B's sweeps set it to now) both set back
T8=$(pq "SELECT now()")
pq "UPDATE pgvigil.admin_sources SET regions_read_at = now() - interval '8 days', sweep_tried_at = now() - interval '8 days', last_run = now() - interval '2 hours' WHERE name = 'aws1'" >/dev/null
R8=$(pq "SELECT regions_read_at FROM pgvigil.admin_sources WHERE name = 'aws1'")
# regions_read_at is written by the sweep's edit just after the read's last_run: wait on it itself
for _ in $(seq 1 240); do [[ "$(pq "SELECT regions_read_at > '$R8'::timestamptz FROM pgvigil.admin_sources WHERE name = 'aws1'")" == t ]] && break; sleep 1; done
[[ "$(pq "SELECT regions_read_at > '$R8'::timestamptz FROM pgvigil.admin_sources WHERE name = 'aws1'")" == t ]] || fail "E12: an 8-day-old sweep was not swept again within 240 s (regions_read_at $R8; last error: $(pq "SELECT coalesce(last_error, '') FROM pgvigil.admin_sources WHERE name = 'aws1'"))"
[[ "$(pq "SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'source read' AND target = 'aws1' AND ui_user = 'the weekly sweep' AND at > '$T8'::timestamptz")" -ge 1 ]] || fail "E12: no read audited as 'the weekly sweep'"
LD=$(pq "SELECT x->>'last' FROM pgvigil.admin_sources, jsonb_array_elements(note_items) x WHERE name = 'aws1' AND x->>'key' = '$DISW'")
[[ -n "$LD" ]] || fail "E12: $DISW has no note after the weekly sweep"
T6=$(pq "SELECT now()")
pq "UPDATE pgvigil.admin_sources SET regions_read_at = now() - interval '6 days', sweep_tried_at = now() - interval '6 days', last_run = now() - interval '2 hours' WHERE name = 'aws1'" >/dev/null
R6=$(pq "SELECT regions_read_at FROM pgvigil.admin_sources WHERE name = 'aws1'"); L6=$(pq "SELECT last_run FROM pgvigil.admin_sources WHERE name = 'aws1'")
loopwait aws1 "$L6" 240; sleep 3   # a sweep's edit and the notes land just after last_run
[[ "$(pq "SELECT regions_read_at = '$R6'::timestamptz FROM pgvigil.admin_sources WHERE name = 'aws1'")" == t ]] || fail "E12: a 6-day-old sweep was swept again"
[[ "$(pq "SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'source read' AND target = 'aws1' AND ui_user = 'the hourly read' AND at > '$T6'::timestamptz")" -ge 1 ]] || fail "E12: the 6-day read is not audited as 'the hourly read'"
echo "ok   E12: regions and the last sweep tried 8 days old: the loop swept aws1 (regions_read_at moved, audited 'the weekly sweep'); 6 days old: an hourly read, no sweep"
# E13 (D4): after the sweep and that hourly read (which asks only the kept regions), the region the account has not
# enabled keeps its note with its first time
N13=$(pq "SELECT coalesce(last_notes, '') FROM pgvigil.admin_sources WHERE name = 'aws1'")
[[ "$N13" == *"$DISW: not enabled for this account (since "*" UTC)"* ]] || fail "E13: the hourly read dropped $DISW's note: $N13"
[[ "$(pq "SELECT x->>'last' FROM pgvigil.admin_sources, jsonb_array_elements(note_items) x WHERE name = 'aws1' AND x->>'key' = '$DISW'")" == "$LD" ]] || fail "E13: $DISW's note was seen again by the hourly read (its last time moved from the sweep's $LD)"
echo "ok   E13: after the weekly sweep and an hourly read, $DISW is still noted 'not enabled for this account (since ...)', its last time the sweep's (not asked by the hourly read)"

# E11 / E11b (D1, the region list refused / not answered): a second serve on the same repository whose environment
# alone points the EC2 call at a local stub (AWS_ENDPOINT_URL_EC2, the SDK's per-service endpoint variable; RDS and STS
# untouched): the stub answers EC2's own refusal (403 UnauthorizedOperation); then its port closed
kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null || true; SRVPID=   # from here only the second serve reads (one loop)
STUBP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
cat > "$TMPD/stub.py" <<'PY'
import http.server, sys
log = open(sys.argv[2], "a")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode(errors="replace")
        log.write(body.split("&")[0] + "\n"); log.flush()
        out = b'<?xml version="1.0" encoding="UTF-8"?><Response><Errors><Error><Code>UnauthorizedOperation</Code><Message>You are not authorized to perform this operation.</Message></Error></Errors><RequestID>proof-e11</RequestID></Response>'
        self.send_response(403); self.send_header("Content-Type", "text/xml"); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$TMPD/stub.py" "$STUBP" "$TMPD/stub.log" & STUBPID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null -X POST "http://127.0.0.1:$STUBP/" && break; sleep 0.1; done; : > "$TMPD/stub.log"
e11serve() { # $1 the EC2 endpoint; starts serve on PORT2, signs in (cookie jar cj2)
  PORT2=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U2="http://127.0.0.1:$PORT2"
  (set -a; . "$CREDS"; set +a; unset AZ_TOKEN; export AWS_ENDPOINT_URL_EC2="$1"; umask 022; exec "$TMPD/pgvigil" serve -config "$CFGD/pgvigil.yaml" -listen "127.0.0.1:$PORT2") >>"$TMPD/serve.log" 2>&1 & SRV2PID=$!
  for _ in $(seq 1 100); do curl -s -o /dev/null "$U2/api/session" 2>/dev/null && break; sleep 0.1; done
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj2" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U2/api/login")" == 200 ]] || fail "E11: the UI login on the second serve"; }
api2() { local c; printf '%s' "$2" > "$TMPD/body.json"; c=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cj2" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/body.json" "$U2/api/$1"); cat "$TMPD/ans.json" >> "$TMPD/answers.log"; echo >> "$TMPD/answers.log"; echo "$c"; }
e11serve "http://127.0.0.1:$STUBP"
code=$(api2 admin/sources "$(js op=add kind=aws name=aws11 aws_profile= aws_regions= every_s=3600)"); [[ "$code" == 200 ]] || fail "E11: aws11: $code $(head -c 300 "$TMPD/ans.json")"
N11=$(pq "SELECT coalesce(last_notes, '') FROM pgvigil.admin_sources WHERE name = 'aws11'")
grep -q '^Action=DescribeRegions$' "$TMPD/stub.log" || fail "E11: the stub got no DescribeRegions call: $(head -c 200 "$TMPD/stub.log")"
[[ "$N11" == *"ec2:DescribeRegions not granted (UnauthorizedOperation): the account's enabled regions were not checked: a region outside RDS's replication list is not read"* ]] || fail "E11: the standing note: $N11"
code=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cj2" -H 'X-Pgvigil: 1' "$U2/api/admin/instances"); [[ "$code" == 200 ]] || fail "E11: GET admin/instances: $code"
python3 -c 'import json, sys
t = json.load(open(sys.argv[1]))["sources"]; i = {c: n for n, c in enumerate(t["columns"])}
r = [x for x in t["rows"] if x[i["name"]] == "aws11"][0]
sys.exit(0 if "ec2:DescribeRegions not granted" in (r[i["last_notes"]] or "") else 1)' "$TMPD/ans.json" || fail "E11: the sources table's 'not seen' (last_notes) in the API answer lacks the note"
# the sweep still keeps RDS's list less the refused (the regions the account has not enabled read and noted by token)
EX11=$(grep '^aws-region|' "$HAND" | cut -d'|' -f2 | grep -vxF -f <(grep -E '^aws-region-(off|denied)\|' "$HAND" | cut -d'|' -f2; echo '^') | sort | tr '\n' ' ' | sed 's/ $//')
G11=$(pq "SELECT array_to_string(cloud_regions, ' ') FROM pgvigil.admin_sources WHERE name = 'aws11'")
SIL=$(pq "SELECT string_agg(x->>'key', ' ' ORDER BY x->>'key') FROM pgvigil.admin_sources, jsonb_array_elements(note_items) x WHERE name = 'aws11' AND x->>'text' LIKE (x->>'key') || ': not reachable%'")
minus() { tr ' ' '\n' <<<"$1" | grep . | grep -vxF -f <(tr ' ' '\n' <<<"$2" | grep .; echo '^') | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
# a region silent to the box but answered on the laptop (or the other way) is not graded: section D's rule
[[ "$(minus "$G11" "$SIL")" == "$(minus "$EX11" "$UNREACH")" ]] || fail "E11: aws11 keeps [$G11] less the silent [$SIL], want RDS's list less the refused [$EX11] less the CLI's unreachable [$UNREACH]"
# E1 / D5 under the stub (the 12:27 amend): a region silent to the box is kept, noted 'not reachable (since ...)', and
# the next read, the loop's, does not ask it (its note's last time unchanged, its servers unseen)
if [[ -n "$SIL" ]]; then
  S1=$(cut -d' ' -f1 <<<"$SIL")
  [[ " $G11 " == *" $S1 "* && "$N11" == *"$S1: not reachable"*"(since "* ]] || fail "E11/D5: the silent $S1 is not kept with its since time: [$G11] $N11"
  LS=$(pq "SELECT x->>'last' FROM pgvigil.admin_sources, jsonb_array_elements(note_items) x WHERE name = 'aws11' AND x->>'key' = '$S1'")
  LOK=$(pq "SELECT coalesce(last_ok, '-infinity')::text FROM pgvigil.admin_sources WHERE name = 'aws11'")
  pq "UPDATE pgvigil.admin_sources SET last_run = now() - interval '2 hours' WHERE name = 'aws11'" >/dev/null; L11=$(pq "SELECT last_run FROM pgvigil.admin_sources WHERE name = 'aws11'")
  for _ in $(seq 1 240); do [[ "$(pq "SELECT last_run > '$L11'::timestamptz FROM pgvigil.admin_sources WHERE name = 'aws11'")" == t ]] && break; sleep 1; done
  [[ "$(pq "SELECT last_run > '$L11'::timestamptz FROM pgvigil.admin_sources WHERE name = 'aws11'")" == t ]] || fail "E11/D5: the loop did not read aws11"
  # the read succeeded, and its notes are in (the standing note, keyed 'source', is written by every read under the
  # stub, after last_run)
  [[ "$(pq "SELECT (last_error IS NULL AND last_ok > '$LOK'::timestamptz)::text FROM pgvigil.admin_sources WHERE name = 'aws11'")" == true ]] || fail "E11/D5: the loop's read of aws11 failed: $(pq "SELECT coalesce(last_error, '') FROM pgvigil.admin_sources WHERE name = 'aws11'")"
  LR=$(pq "SELECT last_run FROM pgvigil.admin_sources WHERE name = 'aws11'")
  for _ in $(seq 1 30); do [[ "$(pq "SELECT count(*) FROM pgvigil.admin_sources, jsonb_array_elements(note_items) x WHERE name = 'aws11' AND x->>'key' = 'source' AND (x->>'last')::timestamptz >= '$LR'::timestamptz")" -ge 1 ]] && break; sleep 1; done
  [[ "$(pq "SELECT count(*) FROM pgvigil.admin_sources, jsonb_array_elements(note_items) x WHERE name = 'aws11' AND x->>'key' = 'source' AND (x->>'last')::timestamptz >= '$LR'::timestamptz")" -ge 1 ]] || fail "E11/D5: the loop's read wrote no notes within 30 s"
  [[ "$(pq "SELECT x->>'last' FROM pgvigil.admin_sources, jsonb_array_elements(note_items) x WHERE name = 'aws11' AND x->>'key' = '$S1'")" == "$LS" ]] || fail "E11/D5: the loop's read asked $S1 again (its note's last time moved)"
  [[ "$(pq "SELECT coalesce(last_notes, '') FROM pgvigil.admin_sources WHERE name = 'aws11'")" == *"$S1: not reachable"* ]] || fail "E11/D5: $S1's note was dropped by the loop's read"
  D5="; $S1 silent to the box: kept, noted 'not reachable (since ...)', and the loop's next read did not ask it (its note's last time unchanged)"
else D5=""; NPD5="; D5 (a region silent to the box left out of the next read): no region was silent to the box this run"; fi
kill "$SRV2PID" 2>/dev/null; wait "$SRV2PID" 2>/dev/null || true; SRV2PID=
echo "ok   E11: the EC2 call refused (the stub's 403 UnauthorizedOperation, one DescribeRegions call seen there): the standing note 'ec2:DescribeRegions not granted' on aws11 and in the API's sources table ('not seen'); the sweep kept RDS's list less the refused [$G11]$D5"
[[ -n "$NPD5" ]] && echo "NOT PROVEN${NPD5#;}"
kill "$STUBPID" 2>/dev/null; wait "$STUBPID" 2>/dev/null || true; STUBPID=
e11serve "http://127.0.0.1:$STUBP"   # the stub's port now closed
code=$(api2 admin/sources "$(js op=sync name=aws11)"); [[ "$code" == 200 ]] || fail "E11b: Read now: $code $(head -c 300 "$TMPD/ans.json")"
N11b=$(pq "SELECT coalesce(last_notes, '') FROM pgvigil.admin_sources WHERE name = 'aws11'")
[[ "$N11b" == *"ec2:DescribeRegions not answered"*"the account's enabled regions were not checked"* && "$N11b" != *"not granted"* ]] || fail "E11b: the standing note with the port closed: $N11b"
code=$(api2 admin/sources "$(js op=remove name=aws11)"); [[ "$code" == 200 ]] || fail "E11b: remove aws11: $code"
kill "$SRV2PID" 2>/dev/null; wait "$SRV2PID" 2>/dev/null || true; SRV2PID=
echo "ok   E11b: the EC2 endpoint's port closed: 'ec2:DescribeRegions not answered (...)' with the standing note on Read now"
echo "== F. no credential anywhere (after every row) =="
# every row of every pgvigil table as text into a file, then searched by a script that reads the secrets from the
# credentials file itself: no secret on a command line or in a statement
: > "$TMPD/dump.txt"; NT=0
for t in $(pq "SELECT c.oid::regclass FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'p') AND NOT c.relispartition ORDER BY 1"); do
  NT=$((NT + 1)); psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "SELECT x::text FROM $t x" >> "$TMPD/dump.txt"; done
python3 - "$CREDS" "$TMPD/dump.txt" "$TMPD/serve.log" "$TMPD/answers.log" "$TMPD/b.out" $(find "$CFGD" -type f) <<'PY' || fail "F: a credential is in the repository, serve's log, an API answer, the page walk or a file serve wrote"
import sys
creds = dict(l.rstrip("\n").split("=", 1) for l in open(sys.argv[1]) if "=" in l)
secrets = {k: v for k, v in creds.items() if k in ("AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AZ_TOKEN") and len(v) >= 16}
bad = 0
for f in sys.argv[2:]:
    text = open(f, errors="replace").read()
    for k, v in secrets.items():
        if v in text:
            print("F: %s is in %s" % (k, f.rsplit("/", 1)[-1])); bad = 1
print("F: %d secret(s) searched in the dump, serve's log, every API answer, the page walk and %d file(s) serve wrote" % (len(secrets), len(sys.argv) - 6))
sys.exit(bad)
PY
echo "ok   F: $NT tables read as text after every row, no credential found"
echo "NOT PROVEN (no lab or a billed resource): GovCloud / China regions and ec2:DescribeRegions there, RDS's list from an opt-in starting region, Azure Government / China, live Azure and GCP servers, Aurora readers, Multi-AZ DB clusters, replicas, read pools, the Azure and GCP list-only custom roles, the GCP SERVICE_DISABLED project check live$NPD5"
echo "proof-discovery: OK (run; the hand read after the run must equal the one before it: nothing created in a lab)"
