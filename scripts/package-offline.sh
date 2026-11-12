#!/usr/bin/env bash
# package-offline.sh <dist> <version> [--unsigned]: the offline bundles of a release, laid out from its dist folder
# (release.yml calls it after the checksums are signed; scripts/proof-offline.sh calls it on a local build):
#   <dist>/pgvigil-offline-<version>-linux-amd64.tar.gz   one top folder pgvigil-offline-<version>-linux-amd64/
#   <dist>/pgvigil-offline-<version>-windows-amd64.zip    one top folder pgvigil-offline-<version>-windows-amd64/
# Each holds its platform's plain and FIPS 140-3 binaries (Windows: and the app's zip), their SBOMs, the installer,
# the docs (airgap.md, upgrade.md, uninstall.md), SHA256SUMS with its signature, certificate and Sigstore bundle, and
# the three trust-root files written at the release (a convenience: the site compares them with its own,
# docs/airgap.md). Every file but SHA256SUMS and its three signature files must have its line in SHA256SUMS, or the
# script stops: the one signed list then covers everything an installer runs. The tar's entries are root's
# (--owner=0 --group=0 --numeric-owner) so an extract by root never hands a file to the build machine's uid; both
# archives have fixed dates and a fixed order (the same input gives the same bytes).
# --unsigned: the signature and trust-root files may be missing (a local build; the proof's bundle).
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: package-offline.sh <dist> <version> [--unsigned]" >&2; exit 2; }
DIST=$(cd "$1" && pwd); V=$2; UNSIGNED=${3:-}
[[ -z "$UNSIGNED" || "$UNSIGNED" == "--unsigned" ]] || { echo "package-offline: unknown option $UNSIGNED" >&2; exit 2; }
fail() { echo "package-offline: $*" >&2; exit 1; }
SIGFILES=(SHA256SUMS.sig SHA256SUMS.pem SHA256SUMS.bundle)
TRUST=(fulcio.pem rekor.pub ctfe.pub)
DOCS=(airgap.md upgrade.md uninstall.md)
LINUX=("pgvigil_${V}_linux_amd64" "pgvigil_${V}_linux_amd64_fips" "pgvigil_${V}_linux_amd64.cdx.json" install.sh)
WINDOWS=("pgvigil_${V}_windows_amd64.exe" "pgvigil_${V}_windows_amd64_fips.exe" "pgvigil_${V}_windows_amd64.cdx.json"
         "pgvigil-app_${V}_windows_amd64.zip" "pgvigil-app_${V}_windows_amd64.cdx.json" install.ps1)
[[ -f "$DIST/SHA256SUMS" ]] || fail "$DIST/SHA256SUMS is missing"
# a file the bundle carries: present in dist and (the signature trio aside) listed in SHA256SUMS
listed() { awk -v f="$1" '{ n = $2; sub(/^\*/, "", n); if (n == f) found = 1 } END { exit !found }' "$DIST/SHA256SUMS"; }
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
for os in linux windows; do
  top="pgvigil-offline-${V}-${os}-amd64"; mkdir -p "$STAGE/$top"
  if [[ $os == linux ]]; then own=("${LINUX[@]}"); else own=("${WINDOWS[@]}"); fi
  for f in "${own[@]}" "${DOCS[@]}"; do
    [[ -f "$DIST/$f" ]] || fail "$f is missing from $DIST"
    listed "$f" || fail "$f has no line in SHA256SUMS: every file of the bundle must be in the signed list"
    cp -p "$DIST/$f" "$STAGE/$top/$f"
  done
  cp -p "$DIST/SHA256SUMS" "$STAGE/$top/SHA256SUMS"
  for f in "${SIGFILES[@]}"; do
    if [[ -f "$DIST/$f" ]]; then cp -p "$DIST/$f" "$STAGE/$top/$f"
    elif [[ -z "$UNSIGNED" ]]; then fail "$f is missing from $DIST (a release bundle is signed; --unsigned for a local build)"; fi
  done
  for f in "${TRUST[@]}"; do
    if [[ -f "$DIST/$f" ]]; then
      listed "$f" || fail "$f has no line in SHA256SUMS"
      cp -p "$DIST/$f" "$STAGE/$top/$f"
    elif [[ -z "$UNSIGNED" ]]; then fail "$f is missing from $DIST (release.yml writes the trust root before the checksums)"; fi
  done
  chmod 0755 "$STAGE/$top"
  for f in "$STAGE/$top"/*; do
    case "$f" in *.exe|*_amd64|*_amd64_fips|*.sh|*.ps1) chmod 0755 "$f" ;; *) chmod 0644 "$f" ;; esac
  done
done
LT="$DIST/pgvigil-offline-${V}-linux-amd64.tar.gz"
tar -C "$STAGE" --owner=0 --group=0 --numeric-owner --sort=name --mtime='2000-01-01 00:00:00Z' -cf - "pgvigil-offline-${V}-linux-amd64" | gzip -n -9 > "$LT"
WZ="$DIST/pgvigil-offline-${V}-windows-amd64.zip"
python3 -I - "$STAGE" "pgvigil-offline-${V}-windows-amd64" "$WZ" <<'PY'
import os, sys, zipfile
stage, top, out = sys.argv[1:4]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    d = zipfile.ZipInfo(top + "/", (2000, 1, 1, 0, 0, 0)); d.external_attr = (0o40755 << 16) | 0x10; z.writestr(d, b"")
    for name in sorted(os.listdir(os.path.join(stage, top))):
        p = os.path.join(stage, top, name)
        i = zipfile.ZipInfo(top + "/" + name, (2000, 1, 1, 0, 0, 0)); i.compress_type = zipfile.ZIP_DEFLATED
        i.external_attr = (os.stat(p).st_mode & 0o777 | 0o100000) << 16
        with open(p, "rb") as f: z.writestr(i, f.read())
PY
# what each archive holds, read back from the archive itself
echo "$(basename "$LT"): $(tar -tzf "$LT" | grep -vc '/$') files"
echo "$(basename "$WZ"): $(python3 -I -c 'import sys,zipfile; print(sum(1 for n in zipfile.ZipFile(sys.argv[1]).namelist() if not n.endswith("/")))' "$WZ") files"
