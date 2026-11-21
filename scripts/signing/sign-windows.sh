#!/usr/bin/env bash
# sign-windows.sh <dir> - signs every .exe in <dir> in place with SSL.com's CodeSignTool (eSigner), in ONE batch_sign
# call (one one-time password for the batch). The tool is run directly, never through the vendor's action: its zip is
# downloaded here and checked against the SHA-256 below before anything of it runs, then 'java -jar' on the runner's
# own JDK. No malware-scan step (it is optional and makes signings fail).
#
# SIGN_MODE (required, no default): sandbox - the vendor's eSigner sandbox endpoints below; production - the
# endpoints the pinned zip ships with (its conf/code_sign_tool.properties, covered by the zip's SHA-256).
# The account: SIGN_USERNAME, SIGN_PASSWORD, SIGN_TOTP_SECRET (the TOTP seed), SIGN_CREDENTIAL_ID only when the
# account holds more than one signing certificate. Told apart by emptiness alone:
#   all three empty  - not configured: the files stay unsigned, said in one line, exit 0 - unless SIGNING=required,
#                      which makes it a failure (SIGNING is empty or 'required'; any other value is refused);
#   one or two set   - misconfigured: exit 1, naming the empty ones (names only, never a value);
#   all three set    - sign; any failure is exit 1.
# SIGN_TSA_URL (optional) replaces the conf's TSA_URL in either mode (the vendor's RSA endpoint, http://ts.ssl.com/legacy,
# for a verifier that refuses an ECDSA timestamp), so the release can choose it without a change to this script.
# A value is never printed: no 'set -x', and the tool's own output is shown with each value replaced by '***'.
# After the tool, every file must come back with a different SHA-256 (the tool can exit 0 having signed nothing);
# the verify step (verify-windows.sh) is the gate on what the signature is.
set -euo pipefail

CST_VERSION=1.3.2
CST_URL="https://github.com/SSLcom/CodeSignTool/releases/download/v${CST_VERSION}/CodeSignTool-v${CST_VERSION}.zip"
CST_SHA256=f14b1e1ef14bfa1fd00279c363aab0debbf5dcfba0e4bcdce5d22bb771de0e3a   # downloaded and hashed 2026-11-20

# The vendor's sandbox endpoints, from https://www.ssl.com/guide/esigner-demo-credentials-and-certificates/ (read
# 2026-11-20): the page's replacement for conf/code_sign_tool.properties.
SANDBOX_PROPERTIES='CLIENT_ID=qOUeZCCzSqgA93acB3LYq6lBNjgZdiOxQc-KayC3UMw
OAUTH2_ENDPOINT=https://oauth-sandbox.ssl.com/oauth2/token
CSC_API_ENDPOINT=https://cs-try.ssl.com
TSA_URL=http://ts.ssl.com'

die() { echo "sign-windows: $*" >&2; exit 1; }
[ $# -eq 1 ] && [ -d "$1" ] || die "usage: SIGN_MODE=sandbox|production sign-windows.sh <dir>"
dir=$(cd "$1" && pwd)
mode="${SIGN_MODE:-}"
case "$mode" in sandbox|production) ;; *) die "SIGN_MODE must be 'sandbox' or 'production' (it is '${mode}')" ;; esac
case "${SIGNING:-}" in ''|required) ;; *) die "SIGNING must be empty or 'required' (it is '${SIGNING}')" ;; esac
case "${SIGN_TSA_URL:-}" in ''|http://*|https://*) ;; *) die "SIGN_TSA_URL must be an http or https address" ;; esac

set_n=0; empty=()
for v in SIGN_USERNAME SIGN_PASSWORD SIGN_TOTP_SECRET; do
  if [ -n "${!v:-}" ]; then set_n=$((set_n + 1)); else empty+=("$v"); fi
done
if [ $set_n -eq 0 ]; then
  [ "${SIGNING:-}" = required ] && die "SIGNING is required and no signing account is configured (SIGN_USERNAME, SIGN_PASSWORD and SIGN_TOTP_SECRET are all empty)"
  echo "UNSIGNED: no signing account is configured (all three values empty); the files in $dir stay unsigned"
  exit 0
fi
[ $set_n -eq 3 ] || die "misconfigured: $set_n of the three signing values are set; empty: ${empty[*]} (set all three, or none)"

shopt -s nullglob
files=("$dir"/*.exe)
[ ${#files[@]} -ge 1 ] || die "no .exe file in $dir"
[ ${#files[@]} -le 100 ] || die "${#files[@]} files: one batch_sign takes at most 100"
command -v java >/dev/null || die "java is not on PATH (the runner's own JDK is used)"

work=$(mktemp -d); trap 'rm -rf -- "$work"' EXIT
zip="${CST_ZIP:-}"
if [ -z "$zip" ]; then zip="$work/cst.zip"; curl -fsSL --retry 3 -o "$zip" "$CST_URL" || die "the download of $CST_URL failed"
else [ -f "$zip" ] || die "CST_ZIP $zip is not a file"; zip=$(cd "$(dirname -- "$zip")" && pwd)/$(basename -- "$zip"); fi
got=$(sha256sum "$zip" | cut -d' ' -f1)
[ "$got" = "$CST_SHA256" ] || die "CodeSignTool's zip has SHA-256 $got, not the pinned $CST_SHA256: nothing of it is run"
mkdir "$work/cst" "$work/in" "$work/out"
(cd "$work/cst" && unzip -q "$zip" -x '__MACOSX/*') || die "the zip does not unpack"
jar="$work/cst/jar/code_sign_tool-${CST_VERSION}.jar"
[ -f "$jar" ] || die "the zip holds no jar/code_sign_tool-${CST_VERSION}.jar"
[ "$mode" = sandbox ] && printf '%s\n' "$SANDBOX_PROPERTIES" > "$work/cst/conf/code_sign_tool.properties"
if [ -n "${SIGN_TSA_URL:-}" ]; then
  conf="$work/cst/conf/code_sign_tool.properties"; grep -v '^TSA_URL=' "$conf" > "$conf.new" || true
  printf 'TSA_URL=%s\n' "$SIGN_TSA_URL" >> "$conf.new"; mv "$conf.new" "$conf"
fi
echo "sign-windows: CodeSignTool ${CST_VERSION} (sha256 ${CST_SHA256:0:16}...), mode $mode, endpoints: $(grep -E '^(OAUTH2_ENDPOINT|CSC_API_ENDPOINT|TSA_URL)=' "$work/cst/conf/code_sign_tool.properties" | tr '\n' ' ')"

declare -A before
for f in "${files[@]}"; do
  cp -- "$f" "$work/in/"; before[$(basename -- "$f")]=$(sha256sum -- "$f" | cut -d' ' -f1)
done
args=(batch_sign "-username=$SIGN_USERNAME" "-password=$SIGN_PASSWORD" "-totp_secret=$SIGN_TOTP_SECRET"
      "-input_dir_path=$work/in" "-output_dir_path=$work/out")
[ -n "${SIGN_CREDENTIAL_ID:-}" ] && args+=("-credential_id=$SIGN_CREDENTIAL_ID")
# the tool runs from its own folder (it reads conf/ relative to it)
log=$( (cd "$work/cst" && java -jar "$jar" "${args[@]}" </dev/null) 2>&1 ) && rc=0 || rc=$?
for v in SIGN_PASSWORD SIGN_TOTP_SECRET SIGN_USERNAME SIGN_CREDENTIAL_ID; do
  val="${!v:-}"; [ -n "$val" ] && log="${log//"$val"/***}"
done
printf '%s\n' "$log" | sed 's/^/  tool: /'
[ $rc -eq 0 ] || die "batch_sign exited $rc"

n=0
for f in "${files[@]}"; do
  b=$(basename -- "$f"); s="$work/out/$b"
  [ -s "$s" ] || die "the tool exited 0 but wrote no signed $b"
  after=$(sha256sum -- "$s" | cut -d' ' -f1)
  [ "$after" != "${before[$b]}" ] || die "$b came back unchanged (not signed)"
  cp -- "$s" "$f"; n=$((n + 1))
  echo "signed $b: ${before[$b]:0:16}... -> ${after:0:16}..."
done
echo "sign-windows: $n of ${#files[@]} file(s) signed in $dir ($mode)"
