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
# POSIX sh (dash, busybox ash, bash): no arrays, no [[ ]], no local. Needs curl or wget, and sha256sum or shasum.
set -eu

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
