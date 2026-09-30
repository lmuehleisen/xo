#!/usr/bin/env bash
# fm-install-gitleaks.sh - install the pinned, verified gitleaks build that the
# publish gate (bin/fm-publish-gate.sh) and its CI checks use.
#
# Downloads the official GitHub release archive for the host OS/arch, verifies
# its per-archive SHA-256 pin, and installs the binary into the destination
# directory. Supported platforms: linux x86_64/amd64, linux arm64/aarch64,
# darwin x86_64/amd64, darwin arm64/aarch64. Pins come from the official
# gitleaks release checksums file. Verification uses sha256sum when present,
# otherwise shasum -a 256. An unsupported OS/arch fails without downloading.
#
# Usage:
#   fm-install-gitleaks.sh <destination-directory>
set -eu

VERSION=8.30.1

die() {
  printf 'fm-install-gitleaks.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-gitleaks.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
# SHA-256 pins are from gitleaks_8.30.1_checksums.txt on the official v8.30.1
# release (https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1).
case "${os}-${arch}" in
  Linux-x86_64|Linux-amd64)
    ARCHIVE="gitleaks_${VERSION}_linux_x64.tar.gz"
    SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE="gitleaks_${VERSION}_linux_arm64.tar.gz"
    SHA256=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
    ;;
  Darwin-x86_64|Darwin-amd64)
    ARCHIVE="gitleaks_${VERSION}_darwin_x64.tar.gz"
    SHA256=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709
    ;;
  Darwin-arm64|Darwin-aarch64)
    ARCHIVE="gitleaks_${VERSION}_darwin_arm64.tar.gz"
    SHA256=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
    ;;
  *)
    die "unsupported platform ${os}-${arch}; need linux or darwin on x86_64/amd64 or arm64/aarch64"
    ;;
esac

URL="https://github.com/gitleaks/gitleaks/releases/download/v${VERSION}/${ARCHIVE}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-gitleaks.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=6
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || die "download failed after $DOWNLOAD_ATTEMPTS attempts"
  printf 'fm-install-gitleaks.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep $((1 << (download_attempt - 1)))
  download_attempt=$((download_attempt + 1))
done

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the gitleaks archive"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ARCHIVE (expected $SHA256, got $ACTUAL_SHA256)"

tar -xzf "$TMP/$ARCHIVE" -C "$TMP" gitleaks
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/gitleaks" "$DESTINATION/gitleaks"
"$DESTINATION/gitleaks" version
