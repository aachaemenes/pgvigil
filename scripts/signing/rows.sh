#!/usr/bin/env bash
# rows.sh - the signing scripts' and the proof workflow's own rows, offline (no network, no account): the workflow's
# text holds no deployment environment, no stored-secret reference, no tag trigger and no write permission, and every
# artifact it keeps says SANDBOX and goes within days; sign-windows.sh's three states by emptiness and its refusal of a
# zip that is not the pinned one before any of it runs; verify-windows.sh's refusal of an unsigned file and of no mode.
# M rows: each form that would dodge W1, W2 or W5 (a quoted key or value, a secrets index, toJSON(secrets), secrets:
# inherit, a quoted write-all), added to a copy of the workflow, is caught.
# rows.sh <unsigned PE>: also F1-F3, forged signatures made here on that file with throwaway certificates (osslsigncode
# sign, no network): each must FAIL the verify for the right reason.
# Every value below is a plainly fake test string. Exit 0 only when every row holds; each row prints 'ok' or 'FAIL'.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd); repo=$(cd "$here/../.." && pwd)
wf="$repo/.github/workflows/sign-proof.yml"; sign="$here/sign-windows.sh"; verify="$here/verify-windows.sh"
bad=0
row() { if [ "$1" = ok ]; then echo "ok   $2"; else echo "FAIL $2${3:+ - $3}"; bad=1; fi; }
check() { local name="$1"; shift; if "$@"; then row ok "$name"; else row fail "$name"; fi; }
neg() { ! "$@"; }
w1() { ! grep -niE "[\"']?environment[\"']?[[:space:]]*:" "$1" >/dev/null; }
w2() { ! grep -niE "secrets" "$1" >/dev/null; }
w5() { grep -qE "^permissions:$" "$1" && [ "$(awk '/^permissions:/{f=1;next} f&&/^[^[:space:]]/{exit} f' "$1" | grep -cE "[a-z]")" -eq 1 ] &&
       awk '/^permissions:/{f=1;next} f&&/^[^[:space:]]/{exit} f' "$1" | grep -qE "^  contents: read$" &&
       ! grep -niE ":[[:space:]]*[\"']?write|write-all|id-token" "$1" >/dev/null; }

# --- the workflow's text
[ -f "$wf" ] || { echo "FAIL the workflow $wf is missing"; exit 1; }
check "W1 no 'environment:' key in sign-proof.yml (quoted or not)" w1 "$wf"
check "W2 the word 'secrets' nowhere in sign-proof.yml (secrets.X, secrets[...], toJSON(secrets), secrets: inherit)" w2 "$wf"
check "W3 no tag trigger in sign-proof.yml" bash -c '! grep -nE "^[[:space:]]*tags(-ignore)?[[:space:]]*:" "$1"' _ "$wf"
check "W4 triggers: a push to branch sign-proof and workflow_dispatch, nothing else" bash -c '
  on=$(awk "/^on:/{f=1;next} f&&/^[^[:space:]#]/{exit} f" "$1")
  grep -qE "^  push:" <<<"$on" && grep -qE "^    branches: \[sign-proof\]$" <<<"$on" && grep -qE "^  workflow_dispatch:" <<<"$on" &&
  [ "$(grep -cE "^  [a-z_]+:" <<<"$on")" -eq 2 ]' _ "$wf"
check "W5 permissions: contents: read at the top, no write and no id-token anywhere" w5 "$wf"
check "W6 no release and no publish (no gh release, no release action, no tag push)" bash -c '! grep -niE "gh release|action-gh-release|create-release|upload-release|git push|git tag" "$1"' _ "$wf"
check "W7 every uploaded artifact's name says SANDBOX and is kept 5 days or fewer" bash -c '
  n=$(grep -cE "uses: actions/upload-artifact@" "$1"); [ "$n" -ge 1 ] || exit 1
  [ "$(grep -A6 -E "uses: actions/upload-artifact@" "$1" | grep -cE "^[[:space:]]+name: [^[:space:]]*SANDBOX")" -eq "$n" ] &&
  [ "$(grep -A8 -E "uses: actions/upload-artifact@" "$1" | grep -cE "^[[:space:]]+retention-days: [1-5]$")" -eq "$n" ]' _ "$wf"
check "W8 the three files never name the release secrets (ES_...)" bash -c '! grep -nE "ES_[A-Z]" "$1" "$2" "$3"' _ "$wf" "$sign" "$verify"
check "W9 sign-proof.yml commits SIGN_MODE sandbox and runs the two scripts" bash -c '
  grep -qE "^[[:space:]]+SIGN_MODE: sandbox$" "$1" && grep -qE "scripts/signing/sign-windows.sh" "$1" && grep -qE "scripts/signing/verify-windows.sh" "$1" &&
  ! grep -qE "SIGN_MODE: production$" "$1"' _ "$wf"

# --- the forms that would dodge W1, W2 and W5, each added to a copy of the workflow: each must be caught
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
mrow() { local name="$1" fn="$2" line="$3"; { cat "$wf"; printf '%s\n' "$line"; } > "$tmp/mutant.yml"; check "$name" neg "$fn" "$tmp/mutant.yml"; }
mrow "M1 W1 catches a quoted key ('\"environment\": release')" w1 '      "environment": release'
mrow "M2 W2 catches a secrets index ('\${{ secrets[...] }}')" w2 "          X: \${{ secrets['NOT_A_SECRET'] }}"
mrow "M3 W2 catches toJSON(secrets)" w2 '          X: ${{ toJSON(secrets) }}'
mrow "M4 W2 catches 'secrets: inherit'" w2 '    secrets: inherit'
mrow "M5 W5 catches a quoted write ('contents: \"write\"')" w5 '      contents: "write"'
mrow "M6 W5 catches a quoted write-all ('permissions: \"write-all\"')" w5 '    permissions: "write-all"'

# --- sign-windows.sh, offline: a stand-in java that leaves a mark if anything runs it
mkdir -p "$tmp/bin" "$tmp/files"
printf '#!/bin/sh\ntouch "%s/java-ran"\nexit 0\n' "$tmp" > "$tmp/bin/java"; chmod +x "$tmp/bin/java"
printf 'MZ not a real program\n' > "$tmp/files/a.exe"; h0=$(sha256sum "$tmp/files/a.exe" | cut -d' ' -f1)
printf 'not the vendor zip\n' > "$tmp/wrong.zip"
runsign() { env -u SIGN_USERNAME -u SIGN_PASSWORD -u SIGN_TOTP_SECRET -u SIGNING PATH="$tmp/bin:$PATH" "$@" bash "$sign" "$tmp/files" > "$tmp/out" 2>&1; echo $? > "$tmp/rc"; }
rc() { cat "$tmp/rc"; }
has() { grep -qF -- "$1" "$tmp/out"; }
runsign SIGN_MODE=
check "S1 no SIGN_MODE: refused (exit 1)" bash -c '[ "$1" -eq 1 ]' _ "$(rc)"; has "SIGN_MODE must be" || row fail "S1 words" "$(head -c 300 "$tmp/out")"
runsign SIGN_MODE=sandbox
check "S2 all three empty: not configured, exit 0, the file unchanged" bash -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ]' _ "$(rc)" "$h0" "$(sha256sum "$tmp/files/a.exe" | cut -d' ' -f1)"
has "UNSIGNED: no signing account is configured" || row fail "S2 words" "$(head -c 300 "$tmp/out")"
runsign SIGN_MODE=production SIGNING=required
check "S3 all three empty with SIGNING=required: exit 1" bash -c '[ "$1" -eq 1 ]' _ "$(rc)"; has "SIGNING is required" || row fail "S3 words" "$(head -c 300 "$tmp/out")"
runsign SIGN_MODE=sandbox SIGN_USERNAME=not-a-secret-user
check "S4 one of three set: misconfigured, exit 1, the two empty ones named" bash -c '[ "$1" -eq 1 ]' _ "$(rc)"
has "misconfigured: 1 of the three" && has "SIGN_PASSWORD SIGN_TOTP_SECRET" || row fail "S4 words" "$(head -c 300 "$tmp/out")"
runsign SIGN_MODE=sandbox SIGN_USERNAME=not-a-secret-user SIGN_TOTP_SECRET=not-a-secret-seed
check "S5 two of three set: misconfigured, exit 1, the empty one named" bash -c '[ "$1" -eq 1 ]' _ "$(rc)"
has "misconfigured: 2 of the three" && has "empty: SIGN_PASSWORD" || row fail "S5 words" "$(head -c 300 "$tmp/out")"
grep -qF "not-a-secret" "$tmp/out" && row fail "S5 a value printed" "$(head -c 300 "$tmp/out")"
rm -f "$tmp/java-ran"
runsign SIGN_MODE=sandbox SIGN_USERNAME=not-a-secret-user SIGN_PASSWORD=not-a-secret-password SIGN_TOTP_SECRET=not-a-secret-seed CST_ZIP="$tmp/wrong.zip"
check "S6 all set, a zip that is not the pinned one: exit 1 before any of it runs" bash -c '[ "$1" -eq 1 ] && [ ! -e "$2/java-ran" ]' _ "$(rc)" "$tmp"
has "not the pinned f14b1e1e" || row fail "S6 words" "$(head -c 300 "$tmp/out")"
for v in Required true require; do
  runsign SIGN_MODE=sandbox SIGNING=$v
  check "S8 SIGNING '$v' (neither empty nor 'required'): refused, exit 1" bash -c '[ "$1" -eq 1 ]' _ "$(rc)"; has "SIGNING must be empty or 'required'" || row fail "S8 words ($v)" "$(head -c 300 "$tmp/out")"
done
check "S7 the pin: the zip's address and SHA-256 are constants of sign-windows.sh" bash -c '
  grep -qE "^CST_SHA256=f14b1e1ef14bfa1fd00279c363aab0debbf5dcfba0e4bcdce5d22bb771de0e3a( |$)" "$1" &&
  grep -qE "^CST_URL=\"https://github.com/SSLcom/CodeSignTool/releases/download/" "$1"' _ "$sign"

# --- verify-windows.sh, offline
SIGN_MODE= bash "$verify" "$tmp/files/a.exe" > "$tmp/out" 2>&1; echo $? > "$tmp/rc"
check "V1 no SIGN_MODE: refused (exit 2)" bash -c '[ "$1" -eq 2 ]' _ "$(rc)"
if command -v osslsigncode >/dev/null; then
  SIGN_MODE=sandbox bash "$verify" "$tmp/files/a.exe" > "$tmp/out" 2>&1; echo $? > "$tmp/rc"
  check "V2 an unsigned file: FAIL not signed, exit 1" bash -c '[ "$1" -eq 1 ] && grep -qE "^FAIL a.exe: not signed" "$2"' _ "$(rc)" "$tmp/out"
else
  row fail "V2 an unsigned file" "osslsigncode is not installed here"
fi
check "V3 the roots file holds six certificates, the sandbox CA file one" bash -c '[ "$(grep -c "BEGIN CERTIFICATE" "$1")" -eq 6 ] && [ "$(grep -c "BEGIN CERTIFICATE" "$2")" -eq 1 ]' _ "$here/ssl.com-roots.pem" "$here/ssl.com-sandbox-ca.pem"

# --- forged signatures on a real PE (rows.sh <unsigned PE>): throwaway certificates, no network
if [ $# -ge 1 ]; then
  pe="$1"; f="$tmp/forge"; mkdir -p "$f"
  if ! command -v osslsigncode >/dev/null || [ ! -s "$pe" ]; then row fail "F rows" "osslsigncode or the PE $pe is missing"
  else
    sslq() { openssl "$@" >/dev/null 2>&1; }
    ext() { printf '%s\n' "$@" > "$f/ext.cnf"; echo "$f/ext.cnf"; }
    # a test root R and a code-signing certificate X it issued
    sslq req -x509 -newkey rsa:2048 -nodes -keyout "$f/R.key" -out "$f/R.pem" -days 2 -subj "/CN=rows test root" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
    sslq req -newkey rsa:2048 -nodes -keyout "$f/X.key" -out "$f/X.csr" -subj "/CN=rows signer X"
    sslq x509 -req -in "$f/X.csr" -CA "$f/R.pem" -CAkey "$f/R.key" -set_serial 0x5A5A5A5A5A5A5A5A5A5A -days 2 -out "$f/X.pem" -extfile "$(ext basicConstraints=CA:FALSE keyUsage=digitalSignature extendedKeyUsage=codeSigning)"
    # planted beside it: F (the production subject, self-made, a leaf by shape), C (subject A, issued by a self-made
    # 'rows signer X', so X is no leaf by shape), and A / B issuing each other (no leaf by shape)
    sslq req -x509 -newkey rsa:2048 -nodes -keyout "$f/F.key" -out "$f/F.pem" -days 2 -subj "/CN=rows production subject"
    sslq req -x509 -newkey rsa:2048 -nodes -keyout "$f/FX.key" -out "$f/FX.pem" -days 2 -subj "/CN=rows signer X"
    sslq req -x509 -newkey rsa:2048 -nodes -keyout "$f/A.key" -out "$f/A0.pem" -days 2 -subj "/CN=rows pair A"
    sslq req -x509 -newkey rsa:2048 -nodes -keyout "$f/B.key" -out "$f/B0.pem" -days 2 -subj "/CN=rows pair B"
    sslq req -new -key "$f/A.key" -out "$f/A.csr" -subj "/CN=rows pair A"; sslq req -new -key "$f/B.key" -out "$f/B.csr" -subj "/CN=rows pair B"
    sslq x509 -req -in "$f/A.csr" -CA "$f/FX.pem" -CAkey "$f/FX.key" -set_serial 11 -days 2 -out "$f/C.pem"
    sslq x509 -req -in "$f/A.csr" -CA "$f/B0.pem" -CAkey "$f/B.key" -set_serial 12 -days 2 -out "$f/Acert.pem"
    sslq x509 -req -in "$f/B.csr" -CA "$f/A0.pem" -CAkey "$f/A.key" -set_serial 13 -days 2 -out "$f/Bcert.pem"
    cat "$f/F.pem" "$f/C.pem" "$f/Acert.pem" "$f/Bcert.pem" > "$f/extras.pem"
    osslsigncode sign -certs "$f/X.pem" -key "$f/X.key" -ac "$f/extras.pem" -in "$pe" -out "$f/forged1.exe" >/dev/null 2>&1
    # a copy of the verify script whose roots are R and whose production subject is F's
    sed -e "s|^here=.*|here='$here'|" -e "s|^ROOTS=.*|ROOTS='$f/R.pem'|" -e "s|^PRODUCTION_SUBJECT=.*|PRODUCTION_SUBJECT='CN=rows production subject'|" "$verify" > "$f/verify-copy.sh"
    SIGN_MODE=production bash "$f/verify-copy.sh" "$f/forged1.exe" > "$tmp/out" 2>&1; echo $? > "$tmp/rc"
    check "F1 a signature by X with F (the production subject) planted in its list: FAIL, the signer is X, not F" bash -c '[ "$1" -eq 1 ] && grep -qE "^signer .*: CN=rows signer X$" "$2" && grep -qE "^FAIL .*the signer is not .CN=rows production subject." "$2"' _ "$(rc)" "$tmp/out"
    # a self-made certificate that copies the demo subject, in sandbox mode
    sslq req -x509 -newkey rsa:2048 -nodes -keyout "$f/D.key" -out "$f/D.pem" -days 2 -subj "/C=US/ST=Texas/L=Houston/O=Esigner LLC/OU=Cloud Signing Demo/serialNumber=0123456789/CN=Esigner LLC/businessCategory=Private Organization/jurisdictionC=US" -addext "extendedKeyUsage=codeSigning"
    osslsigncode sign -certs "$f/D.pem" -key "$f/D.key" -in "$pe" -out "$f/forged2.exe" >/dev/null 2>&1
    SIGN_MODE=sandbox bash "$verify" "$f/forged2.exe" > "$tmp/out" 2>&1; echo $? > "$tmp/rc"
    check "F2 a self-made certificate with the demo subject, sandbox mode: FAIL, not issued by the vendor's sandbox CA" bash -c '[ "$1" -eq 1 ] && grep -qE "^signer .*CN=Esigner LLC" "$2" && grep -qE "^FAIL .*the signer is not issued by the vendor.s sandbox CA" "$2"' _ "$(rc)" "$tmp/out"
    [ $bad -eq 0 ] || sed 's/^/     /' "$tmp/out"
    # a second signature nested in the first
    osslsigncode sign -nest -certs "$f/D.pem" -key "$f/D.key" -in "$f/forged2.exe" -out "$f/nested.exe" >/dev/null 2>&1
    SIGN_MODE=sandbox bash "$verify" "$f/nested.exe" > "$tmp/out" 2>&1; echo $? > "$tmp/rc"
    check "F3 a nested second signature: FAIL, not one signature" bash -c '[ "$1" -eq 1 ] && grep -qE "^FAIL .*signature\(s\) read, not one" "$2"' _ "$(rc)" "$tmp/out"
    # F4: the SignerInfo's issuer patched by one letter's case after signing (outside the signed bytes); a self-made F
    # with that issuer text, X's serial and the production subject planted in the list - osslsigncode matches X
    # (names compared without case), a text match would take F; the leaf hash must refuse it
    sslq req -x509 -newkey rsa:2048 -nodes -keyout "$f/FT.key" -out "$f/FT.pem" -days 2 -subj "/CN=rows Test root"
    sslq req -new -key "$f/F.key" -out "$f/F4.csr" -subj "/CN=rows production subject"
    sslq x509 -req -in "$f/F4.csr" -CA "$f/FT.pem" -CAkey "$f/FT.key" -set_serial 0x5A5A5A5A5A5A5A5A5A5A -days 2 -out "$f/F4.pem" -extfile "$(ext basicConstraints=CA:FALSE keyUsage=digitalSignature extendedKeyUsage=codeSigning)"
    osslsigncode sign -certs "$f/X.pem" -key "$f/X.key" -ac "$f/F4.pem" -in "$pe" -out "$f/forged4.exe" >/dev/null 2>&1
    at=$(grep -obUa 'rows test root' "$f/forged4.exe" | tail -1 | cut -d: -f1)
    [ -n "$at" ] && printf 'T' | dd of="$f/forged4.exe" bs=1 seek=$((at + 5)) conv=notrunc status=none
    SIGN_MODE=production bash "$f/verify-copy.sh" "$f/forged4.exe" > "$tmp/out" 2>&1; echo $? > "$tmp/rc"
    check "F4 the SignerInfo's issuer case-patched, F planted with that text: FAIL, the certificate read is not the one osslsigncode verifies" bash -c '[ "$1" -eq 1 ] && [ -n "$3" ] && grep -qE "^FAIL .*the certificate read as the signer is not the one osslsigncode verifies" "$2"' _ "$(rc)" "$tmp/out" "$at"
    # F5: names that shift a text count - F's issuer holds 'BEGIN CERTIFICATE', G (self-signed) 'cert_info:' as its
    # issuer and subject - refused at the count check, never F's subject as the signer (osslsigncode sorts the list by
    # its DER bytes, helpers.c:218-226 and :729-764, so the order cannot be chosen; both scripts stop at the count)
    sslq req -x509 -newkey rsa:2048 -nodes -keyout "$f/FB.key" -out "$f/FB.pem" -days 2 -subj "/CN=-----BEGIN CERTIFICATE-----"
    sslq x509 -req -in "$f/F4.csr" -CA "$f/FB.pem" -CAkey "$f/FB.key" -set_serial 21 -days 2 -out "$f/F5.pem" -extfile "$(ext basicConstraints=CA:FALSE keyUsage=digitalSignature extendedKeyUsage=codeSigning)"
    sslq req -x509 -newkey rsa:2048 -nodes -keyout "$f/G.key" -out "$f/G.pem" -days 2 -subj "/CN=cert_info:"
    cat "$f/F5.pem" "$f/X.pem" "$f/G.pem" > "$f/f5-chain.pem"
    osslsigncode sign -certs "$f/f5-chain.pem" -key "$f/X.key" -in "$pe" -out "$f/forged5.exe" >/dev/null 2>&1
    SIGN_MODE=production bash "$f/verify-copy.sh" "$f/forged5.exe" > "$tmp/out" 2>&1; echo $? > "$tmp/rc"
    check "F5 planted names that shift a text count: refused at the count check, never F's subject as the signer" bash -c '[ "$1" -eq 1 ] && [ -s "$3" ] && grep -qE "^FAIL .*could not be read" "$2" && ! grep -qE "^signer .*: CN=rows production subject$" "$2"' _ "$(rc)" "$tmp/out" "$f/forged5.exe"
    [ $bad -eq 0 ] || sed 's/^/     /' "$tmp/out"
  fi
fi

if [ $bad -eq 0 ]; then echo "rows: every row holds"; else echo "rows: FAILED"; fi
exit $bad
