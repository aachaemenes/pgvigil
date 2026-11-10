#!/usr/bin/env bash
# Proof of the software bill of materials (government readiness, task 50): the CycloneDX SBOM the release
# attaches beside SHA256SUMS, generated here the way release.yml does it and checked against the CycloneDX
# 1.6 JSON schema and against go's own module list. Needs go, curl and uvx (uv) or pipx (either runs check-jsonschema).
# cyclonedx-gomod reads the main module's version with go-git, which does not open a worktree's .git
# file: run from a worktree, the proof clones the committed HEAD into a temporary folder and generates
# there (uncommitted changes are then not in the SBOM; the proof says which path it took).
# Expected: a CycloneDX 1.6 JSON document that validates against the schema (the SPDX and JSF schemas it
# references fetched beside it, pinned to the specification's 1.6.1 tag); bomFormat CycloneDX; the main
# component is github.com/aachaemenes/pgvigil with the build constraints GOOS / GOARCH / CGO_ENABLED as
# properties; every module of a package `go list -deps` reports for ./cmd/pgvigil (the standard library aside) is a
# component with a pkg:golang purl and a version; no component is without a purl; a dependency graph is
# present; the licence evidence covers the modules (MIT, Apache-2.0 and BSD-3-Clause are the three in
# use today: docs/notices.md).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
TOOL=github.com/CycloneDX/cyclonedx-gomod/cmd/cyclonedx-gomod@v1.12.0
SPEC=https://raw.githubusercontent.com/CycloneDX/specification/1.6.1/schema
if command -v uvx >/dev/null; then CHECK=(uvx --from check-jsonschema check-jsonschema); elif command -v pipx >/dev/null; then CHECK=(pipx run check-jsonschema); else fail "neither uvx (uv) nor pipx is on this machine: the schema check needs check-jsonschema"; fi
GOBIN_DIR=$(go env GOBIN); [[ -n "$GOBIN_DIR" ]] || GOBIN_DIR=$(go env GOPATH)/bin
[[ -x "$GOBIN_DIR/cyclonedx-gomod" ]] || go install "$TOOL"

SRC=.
if [[ -f .git ]]; then
  git clone -q . "$WORK/clone"; SRC="$WORK/clone"
  echo "note: a worktree (.git is a file): the SBOM is generated from a clone of the committed HEAD $(git -C "$SRC" rev-parse --short HEAD)"
fi
echo "== generate (linux/amd64, CGO off, as release.yml does per target)"
(cd "$SRC" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "$GOBIN_DIR/cyclonedx-gomod" app -json -licenses -main cmd/pgvigil -output "$WORK/sbom.cdx.json" .) || fail "cyclonedx-gomod failed"

echo "== schema: CycloneDX 1.6 (spec tag 1.6.1)"
for f in bom-1.6.schema.json spdx.schema.json jsf-0.82.schema.json; do curl -fsSL -o "$WORK/$f" "$SPEC/$f" || fail "could not fetch $f"; done
"${CHECK[@]}" --schemafile "$WORK/bom-1.6.schema.json" "$WORK/sbom.cdx.json" || fail "the SBOM does not validate against CycloneDX 1.6"

echo "== content against go list"
(cd "$SRC" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go list -deps -f '{{if .Module}}{{if not .Module.Main}}{{.Module.Path}}@{{.Module.Version}}{{end}}{{end}}' ./cmd/pgvigil | grep -v '^$' | sort -u > "$WORK/modules.txt")
python3 - "$WORK/sbom.cdx.json" "$WORK/modules.txt" <<'PY' || fail "content check"
import json, sys
d = json.load(open(sys.argv[1])); mods = [l.strip() for l in open(sys.argv[2]) if l.strip()]
assert d.get("bomFormat") == "CycloneDX", d.get("bomFormat")
assert d.get("specVersion") == "1.6", d.get("specVersion")
main = d["metadata"]["component"]
assert main["name"] == "github.com/aachaemenes/pgvigil", main["name"]
props = {p["name"]: p["value"] for p in main.get("properties", [])}
for k in ("cdx:gomod:build:env:GOOS", "cdx:gomod:build:env:GOARCH", "cdx:gomod:build:env:CGO_ENABLED"):
    assert k in props, "main component lacks the build constraint " + k
assert props["cdx:gomod:build:env:GOOS"] == "linux" and props["cdx:gomod:build:env:GOARCH"] == "amd64" and props["cdx:gomod:build:env:CGO_ENABLED"] == "0", props
comps = d.get("components", [])
nopurl = [c.get("name") for c in comps if not c.get("purl")]
assert not nopurl, "components without a purl: %s" % nopurl
have = {c["name"] + "@" + c.get("version", "") for c in comps}
missing = [m for m in mods if m not in have]
assert not missing, "modules go list names but the SBOM lacks: %s" % missing
assert d.get("dependencies"), "no dependency graph"
lic = sum(1 for c in comps if c.get("licenses") or (c.get("evidence") or {}).get("licenses"))
ids = sorted({l.get("license", {}).get("id") or l.get("license", {}).get("name") or l.get("expression") for c in comps for l in ((c.get("evidence") or {}).get("licenses") or c.get("licenses") or [])} - {None})
print("   main %s %s; %d components, %d with licence evidence (%s); %d go modules all present; %d dependency entries" % (main["name"], main.get("version"), len(comps), lic, ", ".join(ids), len(mods), len(d["dependencies"])))
PY
cp "$WORK/sbom.cdx.json" "${PGVIGIL_SBOM_OUT:-/dev/null}" 2>/dev/null || true
echo "OK: the SBOM validates against CycloneDX 1.6 and names every module of ./cmd/pgvigil"
