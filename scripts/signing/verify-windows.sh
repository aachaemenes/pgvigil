#!/usr/bin/env bash
# verify-windows.sh <file>... - the gate after the signing step: every Windows file given must carry ONE Authenticode
# signature whose digest matches the file, a timestamp that verifies, and the signer this mode expects. The signing
# tool can exit 0 with no signed file, so this step, not the tool's exit code, decides. Prints each file's signer,
# issuer and timestamp time.
#
# The signer is read from the signature's SignerInfo (its issuer and serial) and then BOUND to osslsigncode's own
# choice: osslsigncode verifies again with -require-leaf-hash of that certificate and must print 'Leaf hash match: ok'
# (osslsigncode 2.8, osslsigncode.c:2669-2675), so a misread list can only fail. The signature itself is verified
# against that certificate in both modes - PKCS7_verify over the signed content, as osslsigncode runs it
# (osslsigncode.c:1940-1976), with the chain left to the step that follows; the code-signing usage is required.
# SIGN_MODE (required, no default; release.yml and sign-proof.yml each commit theirs):
#   production - the chain verifies against SSL.com's roots in ssl.com-roots.pem AND the signer is PRODUCTION_SUBJECT;
#   sandbox    - the signer is the vendor's demo subject, issued by the vendor's sandbox CA (ssl.com-sandbox-ca.pem),
#                AND the chain FAILS against SSL.com's roots (a sandbox file can never pass as a production one).
#                The vendor publishes no development root (its sandbox CA's issuer is '... RSA R2 - Development'), so
#                the sandbox chain is verified to NO root: the signer is checked against the committed sandbox CA and
#                the signature against the signer's own key.
# The timestamp is checked against the system's CA bundle in both modes (the vendor's sandbox uses its public TSA).
# Revocation, as built: osslsigncode's default - it fetches the CRL named by the signer's and the timestamp server's
# certificates (their first http CRL distribution point) and fails the verify when one cannot be fetched (osslsigncode
# 2.8, osslsigncode.c:1828-1838 and :1990-2000); -ignore-cdp without a CRL file would fail every timestamp. What it
# leaves unchecked: an intermediate's revocation (the leaf only, :1513-1514), a certificate that names no http
# distribution point (no check at all, :1988-2001), and the signer's CRL until its chain verifies (never in sandbox).
# Exit 0 only when every file passes; 2 on a usage fault. Needs osslsigncode (2.8 on ubuntu-24.04) and openssl.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ROOTS="$here/ssl.com-roots.pem"
SANDBOX_CA="$here/ssl.com-sandbox-ca.pem"
TSA_ROOTS="${TSA_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"

# The signer's subject, RFC 2253 form, exactly as 'openssl x509 -subject -nameopt RFC2253' prints it.
# Sandbox: the demo certificate of SSL.com's eSigner sandbox (https://www.ssl.com/guide/esigner-demo-credentials-and-certificates/),
# read from a file it signed on 2026-11-21; it expires 2027-07-11 and the vendor may replace it.
SANDBOX_SUBJECT='jurisdictionC=US,businessCategory=Private Organization,CN=Esigner LLC,serialNumber=0123456789,OU=Cloud Signing Demo,O=Esigner LLC,L=Houston,ST=Texas,C=US'
# Production: the issued certificate's subject, committed once it is read from the first file it signs. Empty = every
# production verify fails.
PRODUCTION_SUBJECT=''

die() { echo "verify-windows: $*" >&2; exit 2; }
mode="${SIGN_MODE:-}"
case "$mode" in
  sandbox) want="$SANDBOX_SUBJECT" ;;
  production) want="$PRODUCTION_SUBJECT" ;;
  *) die "SIGN_MODE must be 'sandbox' or 'production' (it is '${mode}')" ;;
esac
[ $# -ge 1 ] || die "usage: SIGN_MODE=sandbox|production verify-windows.sh <file>..."
command -v osslsigncode >/dev/null || die "osslsigncode is not installed"
[ -s "$ROOTS" ] || die "the roots file $ROOTS is missing"
[ -s "$SANDBOX_CA" ] || die "the sandbox CA file $SANDBOX_CA is missing"
[ -s "$TSA_ROOTS" ] || die "the CA bundle for the timestamp, $TSA_ROOTS, is missing"

tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
failed=0
for f in "$@"; do
  name=$(basename -- "$f"); why=()
  if [ ! -f "$f" ]; then echo "FAIL $name: no such file"; failed=1; continue; fi
  rm -f "$tmp"/*
  # an unsigned file first (osslsigncode 2.8's extract-signature crashes on one that has no signature)
  pre=$(osslsigncode verify -in "$f" -CAfile "$ROOTS" -TSA-CAfile "$TSA_ROOTS" 2>&1 || true)
  if grep -q 'No signature found' <<<"$pre" || ! osslsigncode extract-signature -pem -in "$f" -out "$tmp/p7.pem" >/dev/null 2>&1; then
    echo "FAIL $name: not signed (no Authenticode signature)"; failed=1; continue
  fi
  # the signer as read: the first SignerInfo's issuer and serial (the outer signature's; a timestamp or a nested
  # signature sits in its unsigned attributes, after it), matched to exactly one certificate of the list, both read
  # from the one 'openssl pkcs7 -print' text (it writes a serial in decimal or in hex by its size); the n-th
  # certificate there is the n-th of -print_certs, split on the PEM line alone. The leaf hash below binds the result.
  print=$(openssl pkcs7 -in "$tmp/p7.pem" -print 2>/dev/null || true)
  idx=$(awk '
    /signer_info:/ { insi = 1; inci = 0 }
    !insi && /cert_info:/ { n++; inci = 1; next }
    inci && /serialNumber:/ && !(n in ser) { v = $0; sub(/^[^:]*serialNumber: */, "", v); ser[n] = v; next }
    inci && /^ *issuer:/ && !(n in iss) { v = $0; sub(/^[^:]*issuer: */, "", v); iss[n] = v; next }
    insi && /issuer_and_serial:/ && !got { f = 1; next }
    f && /issuer:/ { si = $0; sub(/^[^:]*issuer: */, "", si); next }
    f && /serial:/ { ss = $0; sub(/^[^:]*serial: */, "", ss); f = 0; got = 1 }
    END { if (!got || si == "" || ss == "") { print "unread"; exit }
          printf "%d", n; for (k = 1; k <= n; k++) if (ser[k] == ss && iss[k] == si) printf " %d", k; print "" }' <<<"$print" || true)
  { openssl pkcs7 -in "$tmp/p7.pem" -print_certs 2>/dev/null || true; } | awk -v d="$tmp" '/^-----BEGIN CERTIFICATE-----$/{n++} n{print > (d "/c" n ".pem")}' || true
  ncerts=0; for c in "$tmp"/c*.pem; do [ -f "$c" ] && ncerts=$((ncerts + 1)); done
  read -r nprint matches <<<"${idx} " || true
  if [ "${nprint:-unread}" = unread ] || [ "$nprint" != "$ncerts" ]; then
    echo "FAIL $name: the signature's SignerInfo or its certificate list could not be read (${nprint:-none} / ${ncerts} certificate(s))"; failed=1; continue
  fi
  nmatch=0; k=""
  for m in $matches; do nmatch=$((nmatch + 1)); k=$m; done
  if [ "$nmatch" -ne 1 ]; then
    echo "FAIL $name: ${nmatch} certificate(s) of the signature match its SignerInfo's issuer and serial, not one"; failed=1; continue
  fi
  cert="$tmp/c$k.pem"
  if [ ! -s "$cert" ] || ! openssl x509 -in "$cert" -noout 2>/dev/null; then
    echo "FAIL $name: the certificate read as the signer could not be read"; failed=1; continue
  fi
  leaf=$(openssl x509 -in "$cert" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
  out=$(osslsigncode verify -in "$f" -CAfile "$ROOTS" -TSA-CAfile "$TSA_ROOTS" -require-leaf-hash "sha256:$leaf" 2>&1) && rc=0 || rc=$?
  signer=$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//' || true)
  issuer=$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//' || true)
  echo "signer  $name: $signer"
  echo "issuer  $name: $issuer"
  grep -q '^Leaf hash match: ok' <<<"$out" || why+=("the certificate read as the signer is not the one osslsigncode verifies")
  # the signature against that certificate (PKCS7_verify, no chain): the SpcIndirectDataContent's inner bytes as the
  # signed content - the SEQUENCE under the content info's [0], depth 5 of the DER
  sig=failed
  if openssl pkcs7 -in "$tmp/p7.pem" -outform DER -out "$tmp/p7.der" 2>/dev/null; then
    span=$(openssl asn1parse -inform DER -in "$tmp/p7.der" 2>/dev/null | awk '
      { off = $0; sub(/:.*/, "", off); gsub(/ /, "", off)
        if (!match($0, /d=[0-9]+/)) next; d = substr($0, RSTART + 2, RLENGTH - 2)
        match($0, /hl=[0-9]+/); hl = substr($0, RSTART + 3, RLENGTH - 3)
        match($0, / l= *[0-9]+/); l = substr($0, RSTART + 3, RLENGTH - 3); gsub(/ /, "", l)
        if (want) { if (d == 5 && $0 ~ /cons: SEQUENCE/) print off + hl, l; exit }
        if (d == 4 && $0 ~ /cons: cont \[ 0 \]/) want = 1 }' || true)
    if [ -n "$span" ]; then
      read -r from len <<<"$span"
      tail -c +"$((from + 1))" "$tmp/p7.der" | head -c "$len" > "$tmp/inner.bin" || true
      [ "$(stat -c %s "$tmp/inner.bin")" = "$len" ] &&
        openssl smime -verify -noverify -binary -inform DER -in "$tmp/p7.der" -content "$tmp/inner.bin" -out /dev/null 2>/dev/null && sig=ok
    fi
  fi
  [ "$sig" = ok ] || why+=("the signature does not verify with the signer's own certificate")
  # the signed content is THIS file's: its DigestInfo's digest (the last bytes of the content checked above) must be
  # the digest osslsigncode calculated over the file - text planted where asn1parse prints raw strings cannot move the
  # check onto another file's content
  calc=$(grep -m1 -oE '^Calculated message digest : [0-9A-F]+' <<<"$out" | awk '{print $NF}' || true)
  tie=failed
  if [ -n "$calc" ] && [ -s "$tmp/inner.bin" ]; then
    tail_hex=$(tail -c "$(( ${#calc} / 2 ))" "$tmp/inner.bin" | od -An -tx1 | tr -d ' \n' | tr 'a-f' 'A-F')
    [ "$tail_hex" = "$calc" ] && tie=ok
  fi
  [ "$tie" = ok ] || why+=("the signed content is not this file's (its digest is not the file's calculated digest)")
  openssl x509 -in "$cert" -noout -ext extendedKeyUsage 2>/dev/null | grep -q 'Code Signing' || why+=("the signer's certificate does not carry the code-signing usage")
  nsig=$(sed -n 's/^Number of verified signatures: //p' <<<"$out" | head -1)
  [ "$nsig" = 1 ] || why+=("${nsig:-no} signature(s) read, not one (a nested signature is refused)")
  grep -q 'MISMATCH!!!' <<<"$out" && why+=("a digest does not match the file")
  if grep -q '^Timestamp Server Signature verification: ok' <<<"$out"; then
    echo "stamped $name: $(grep -m1 '^Signature verification time:' <<<"$out" | sed 's/^Signature verification time: //') (the timestamp verifies)"
  else
    why+=("no timestamp, or one that does not verify")
  fi
  chain=failed; [ $rc -eq 0 ] && grep -q '^Signature verification: ok' <<<"$out" && chain=ok
  echo "chain   $name: $chain against SSL.com's roots"
  if [ "$mode" = production ]; then
    [ "$chain" = ok ] || why+=("the chain does not verify against SSL.com's roots")
    [ -n "$want" ] || why+=("no production subject is committed in this script")
    [ -n "$want" ] && [ "$signer" != "$want" ] && why+=("the signer is not '$want'")
  else
    [ "$signer" = "$want" ] || why+=("the signer is not the vendor's demo subject")
    openssl verify -partial_chain -purpose any -CAfile "$SANDBOX_CA" "$cert" >/dev/null 2>&1 || why+=("the signer is not issued by the vendor's sandbox CA")
    [ "$chain" = failed ] || why+=("a sandbox file verifies against SSL.com's production roots")
  fi
  if [ ${#why[@]} -eq 0 ]; then
    echo "PASS $name ($mode)"
  else
    failed=1; reasons=$(printf '%s; ' "${why[@]}"); echo "FAIL $name ($mode): ${reasons%; }"
  fi
done
exit $failed
