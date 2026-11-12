#!/bin/sh
# pgvigil installer for Linux and macOS: finds the release for this OS and CPU, downloads the binary and
# SHA256SUMS, verifies the checksum, then runs `pgvigil install` (Linux: a system account, a systemd unit,
# enabled; started once the config names an instance). Re-run it to upgrade: the binary and the unit are
# replaced, the config is kept.
#
#   curl -fsSL https://pgvigil.com/install.sh | sh
#   PGVIGIL_VERSION=v0.2.0      a given tag (default: the latest release)
#   PGVIGIL_BASE_URL=<url>      the folder that holds <version>/<asset> (default: the GitHub release downloads)
#   PGVIGIL_NO_SERVICE=1        download and verify only; the binary lands in the current folder as ./pgvigil
#
# Offline (no network: a local folder, a mounted USB stick or a share holding the extracted offline bundle,
# pgvigil-offline-<version>-linux-amd64; docs/airgap.md), as root:
#   sh <folder>/install.sh --from <folder> [--fips | --plain] [--trust-root <dir>]
#                          [--owner-dsn-file <path>] [--dump <file> | --no-dump] [--pg-dump <path>]
# The binary and SHA256SUMS are copied into a new folder of root's alone, the copies verified and only the copies run
# (a share or a stick can change between a check and a use). A fresh install runs 'pgvigil install'; on a host where the
# service is installed it is an upgrade, 'pgvigil install -upgrade' (refusals first, then stop, dump, migrate, swap,
# start, the way back printed: docs/upgrade.md), and the installed flavour (FIPS or plain, as 'pgvigil version' says)
# is kept unless --fips or --plain names the other. The checksum proves the files are those SHA256SUMS names (integrity,
# not origin); --trust-root <dir>, a folder with the site's OWN fulcio.pem, rekor.pub and ctfe.pub, also verifies the
# signature of SHA256SUMS with cosign (cosign on the PATH); the trust files inside the bundle are never used for it.
#
# POSIX sh (dash, busybox ash, bash): no arrays, no [[ ]], no local. Needs curl or wget, and sha256sum or shasum.
set -eu

FROM=""; FLAVOUR=""; TRUST=""; UPFLAGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) [ $# -ge 2 ] || { printf 'pgvigil install: --from needs a folder\n' >&2; exit 1; }; FROM=$2; shift 2 ;;
    --fips) FLAVOUR=fips; shift ;;
    --plain) FLAVOUR=plain; shift ;;
    --trust-root) [ $# -ge 2 ] || { printf 'pgvigil install: --trust-root needs a folder\n' >&2; exit 1; }; TRUST=$2; shift 2 ;;
    --owner-dsn-file|--dump|--pg-dump)
      [ $# -ge 2 ] || { printf 'pgvigil install: %s needs a value\n' "$1" >&2; exit 1; }
      case "$2" in *[!A-Za-z0-9/._:+@=-]*) printf 'pgvigil install: %s %s: a path of letters, digits and / . _ - : + @ = only\n' "$1" "$2" >&2; exit 1 ;; esac
      UPFLAGS="$UPFLAGS -${1#--} $2"; shift 2 ;;
    --no-dump) UPFLAGS="$UPFLAGS -no-dump"; shift ;;
    *) printf 'pgvigil install: unknown argument %s (see the header of this script)\n' "$1" >&2; exit 1 ;;
  esac
done
if [ -z "$FROM" ] && { [ -n "$FLAVOUR" ] || [ -n "$TRUST" ] || [ -n "$UPFLAGS" ]; }; then
  printf 'pgvigil install: --fips, --plain, --trust-root and the upgrade flags go with --from\n' >&2; exit 1
fi

REPO="aachaemenes/pgvigil"
BASE="${PGVIGIL_BASE_URL:-https://github.com/$REPO/releases/download}"
VERSION="${PGVIGIL_VERSION:-}"

say() { printf '%s\n' "$*" >&2; }
die() { say "pgvigil install: $*"; exit 1; }

fetch() { # fetch <url> <file>
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1"
  else die "neither curl nor wget is installed"; fi
}

case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=darwin ;;
  *) die "unsupported system $(uname -s): releases exist for Linux and macOS (Windows: install.ps1)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported CPU $(uname -m): releases exist for amd64 and arm64" ;;
esac

if [ -n "$FROM" ]; then
  [ "$OS/$ARCH" = linux/amd64 ] || die "the offline bundle is for Linux on amd64 (this host is $OS/$ARCH)"
  [ -d "$FROM" ] || die "--from $FROM: not a folder"
  [ -f "$FROM/SHA256SUMS" ] || die "--from $FROM: no SHA256SUMS there (the folder is the extracted pgvigil-offline-<version>-linux-amd64)"
  NOSVC=0; [ "${PGVIGIL_NO_SERVICE:-}" = "1" ] && NOSVC=1
  [ "$NOSVC" = 1 ] || [ "$(id -u)" = 0 ] || die "the offline install runs as root: sudo sh $0 --from $FROM ..."
  sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || die "neither sha256sum nor shasum is installed"
  # a new folder of this user's alone (mktemp -d makes it 0700); the copies are checked and only the copies run
  WORK=$(mktemp -d); WORK1=$WORK; WORK2=""
  trap 'rm -rf "$WORK1" "$WORK2"' EXIT
  cp "$FROM/SHA256SUMS" "$WORK/SHA256SUMS"
  # every line names one file: '<64 hex>  <name>' (a '*' before the name is sha256sum's binary mark)
  sumof() { awk -v f="$1" '{ n = $2; sub(/^\*/, "", n); if (n == f) { print $1; c++ } } END { if (c != 1) exit 1 }' "$WORK/SHA256SUMS"; }
  # this script's own bytes against the list, when it runs from the folder (a changed installer is refused)
  if [ -f "$0" ] && [ "$(cd "$(dirname "$0")" && pwd)" = "$(cd "$FROM" && pwd)" ]; then
    want=$(sumof install.sh) || die "SHA256SUMS has no single line for install.sh"
    [ "$(sha "$0")" = "$want" ] || die "checksum mismatch for install.sh itself: this script is not the one SHA256SUMS names"
  fi
  VERSION=$(awk '{ n = $2; sub(/^\*/, "", n); if (n ~ /^pgvigil_v[^_]*_linux_amd64$/) { sub(/^pgvigil_/, "", n); sub(/_linux_amd64$/, "", n); print n } }' "$WORK/SHA256SUMS" | head -n 1)
  [ -n "$VERSION" ] || die "SHA256SUMS names no pgvigil_<version>_linux_amd64"
  if [ -n "$TRUST" ]; then
    command -v cosign >/dev/null 2>&1 || die "--trust-root needs cosign on the PATH"
    for f in fulcio.pem rekor.pub ctfe.pub; do [ -f "$TRUST/$f" ] || die "--trust-root $TRUST: no $f there"; done
    [ -f "$FROM/SHA256SUMS.bundle" ] || die "$FROM has no SHA256SUMS.bundle (an unsigned bundle cannot be verified)"
    cp "$FROM/SHA256SUMS.bundle" "$WORK/SHA256SUMS.bundle"
    SIGSTORE_ROOT_FILE="$TRUST/fulcio.pem" SIGSTORE_REKOR_PUBLIC_KEY="$TRUST/rekor.pub" SIGSTORE_CT_LOG_PUBLIC_KEY_FILE="$TRUST/ctfe.pub" \
      cosign verify-blob --offline --bundle "$WORK/SHA256SUMS.bundle" \
      --certificate-identity "https://github.com/$REPO/.github/workflows/release.yml@refs/tags/$VERSION" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com "$WORK/SHA256SUMS" >/dev/null 2>&1 \
      || die "the signature of SHA256SUMS does not verify against the trust root in $TRUST for $VERSION: nothing was installed"
    say "signature of SHA256SUMS verified (the release workflow of $VERSION, with the trust root in $TRUST)"
  else
    say "signature not verified here: the checksums prove the files are the ones SHA256SUMS names, not where they came from; verify the signature on the connected side, or pass --trust-root <the site's own trust root> (docs/airgap.md)"
  fi
  UNIT=/etc/systemd/system/pgvigil.service
  INSTALLED=""
  if [ -f "$UNIT" ]; then INSTALLED=$(sed -n 's/^ExecStart=\([^ ]*\) run .*/\1/p' "$UNIT" | head -n 1); fi
  if [ -z "$FLAVOUR" ]; then
    FLAVOUR=plain
    if [ -n "$INSTALLED" ] && [ -x "$INSTALLED" ] && "$INSTALLED" version 2>/dev/null | grep -q 'fips140 on'; then FLAVOUR=fips; fi
  elif [ -n "$INSTALLED" ] && [ -x "$INSTALLED" ]; then
    WAS=plain; "$INSTALLED" version 2>/dev/null | grep -q 'fips140 on' && WAS=fips
    [ "$WAS" = "$FLAVOUR" ] || say "the installed build is $WAS; --$FLAVOUR installs the $FLAVOUR build in its place"
  fi
  ASSET="pgvigil_${VERSION}_linux_amd64"; [ "$FLAVOUR" = fips ] && ASSET="${ASSET}_fips"
  [ -f "$FROM/$ASSET" ] || die "$FROM has no $ASSET"
  cp "$FROM/$ASSET" "$WORK/$ASSET"
  want=$(sumof "$ASSET") || die "SHA256SUMS has no single line for $ASSET"
  [ "$(sha "$WORK/$ASSET")" = "$want" ] || die "checksum mismatch for $ASSET: nothing was installed"
  say "pgvigil $VERSION ($FLAVOUR build) checksum verified"
  chmod 0755 "$WORK/$ASSET"
  if ! "$WORK/$ASSET" version >/dev/null 2>&1; then
    # a noexec /tmp: the copy moves to /var/tmp (a new folder of this user's alone again) and is checked again there
    WORK2=$(mktemp -d /var/tmp/pgvigil.XXXXXX 2>/dev/null) || die "the binary cannot run from $WORK (a noexec mount?): set TMPDIR to a folder that allows execution"
    mv "$WORK/$ASSET" "$WORK2/$ASSET"
    [ "$(sha "$WORK2/$ASSET")" = "$want" ] || die "checksum mismatch for $ASSET after the move"
    "$WORK2/$ASSET" version >/dev/null 2>&1 || die "the binary cannot run from $WORK2 either: set TMPDIR to a folder that allows execution"
    WORK="$WORK2"
  fi
  if [ "$NOSVC" = 1 ]; then
    [ -z "$UPFLAGS" ] || die "the upgrade flags go with an install, not with PGVIGIL_NO_SERVICE=1"
    mv "$WORK/$ASSET" ./pgvigil
    say "./pgvigil $VERSION is ready (no service installed)"
    exit 0
  fi
  if [ -n "$INSTALLED" ]; then
    say "an installed collector was found ($UNIT): upgrading it"
    # shellcheck disable=SC2086 # UPFLAGS holds checked words only (letters, digits and path characters)
    "$WORK/$ASSET" install -upgrade $UPFLAGS
  else
    [ -z "$UPFLAGS" ] || die "--owner-dsn-file, --dump, --no-dump and --pg-dump go with an upgrade; no installed collector was found"
    "$WORK/$ASSET" install
  fi
  exit $?
fi

if [ -z "$VERSION" ]; then
  TMPJ=$(mktemp)
  fetch "https://api.github.com/repos/$REPO/releases/latest" "$TMPJ" || die "could not read the latest release; set PGVIGIL_VERSION=vX.Y.Z"
  VERSION=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$TMPJ" | head -n 1)
  rm -f "$TMPJ"
  [ -n "$VERSION" ] || die "the latest release has no tag; set PGVIGIL_VERSION=vX.Y.Z"
fi

ASSET="pgvigil_${VERSION}_${OS}_${ARCH}"
WORK=$(mktemp -d)
WORK2=""
trap 'rm -rf "$WORK" "$WORK2"' EXIT
say "pgvigil $VERSION for $OS/$ARCH"
fetch "$BASE/$VERSION/$ASSET" "$WORK/$ASSET" || die "download failed: $BASE/$VERSION/$ASSET"
fetch "$BASE/$VERSION/SHA256SUMS" "$WORK/SHA256SUMS" || die "download failed: $BASE/$VERSION/SHA256SUMS"

# the checksum line of this asset alone; sha256sum (Linux, busybox) or shasum (macOS)
grep " $ASSET\$" "$WORK/SHA256SUMS" > "$WORK/sum" || die "SHA256SUMS has no line for $ASSET"
if command -v sha256sum >/dev/null 2>&1; then (cd "$WORK" && sha256sum -c sum >/dev/null) || die "checksum mismatch for $ASSET"
elif command -v shasum >/dev/null 2>&1; then (cd "$WORK" && shasum -a 256 -c sum >/dev/null) || die "checksum mismatch for $ASSET"
else die "neither sha256sum nor shasum is installed"; fi
say "checksum verified"
chmod 0755 "$WORK/$ASSET"
# a hardened host mounts /tmp noexec: the binary then runs from /var/tmp instead, or the operator names TMPDIR
if ! "$WORK/$ASSET" version >/dev/null 2>&1; then
  WORK2=$(mktemp -d /var/tmp/pgvigil.XXXXXX 2>/dev/null) || WORK2=""
  if [ -n "$WORK2" ] && mv "$WORK/$ASSET" "$WORK2/$ASSET" && "$WORK2/$ASSET" version >/dev/null 2>&1; then
    WORK="$WORK2"
  else
    die "the downloaded binary cannot run from $WORK (a noexec mount?): set TMPDIR to a folder that allows execution and run again"
  fi
fi

if [ "${PGVIGIL_NO_SERVICE:-}" = "1" ]; then
  mv "$WORK/$ASSET" ./pgvigil
  say "./pgvigil $VERSION is ready (no service installed)"
  exit 0
fi

# the install needs root: already root, else sudo, else say what to run
if [ "$(id -u)" = 0 ]; then
  "$WORK/$ASSET" install
elif command -v sudo >/dev/null 2>&1; then
  say "running 'pgvigil install' with sudo"
  sudo "$WORK/$ASSET" install
else
  mv "$WORK/$ASSET" ./pgvigil
  die "not root and no sudo: run 'su -c \"./pgvigil install\"' with the binary now in the current folder"
fi
