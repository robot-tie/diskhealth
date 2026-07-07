#!/usr/bin/env bash
#
# cut-release.sh — stamp a new immutable release of the DiskHealth agent.
#
# It computes the SHA256 of getdiskhealth.sh, writes it (and the release tag)
# into install.sh and mint-token.sh, then prints the git commands to commit and
# tag. Installs pinned to that tag will refuse any collector whose hash differs.
#
#   ./scripts/cut-release.sh v1.0.0

set -euo pipefail

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "Usage: $0 vX.Y.Z" >&2; exit 1; }
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Version should look like v1.2.3" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v sha256sum >/dev/null || { echo "sha256sum required" >&2; exit 1; }

SHA="$(sha256sum getdiskhealth.sh | awk '{print $1}')"

# Stamp install.sh: the default REF and the embedded expected hash.
sed -i -E \
  -e "s|^REF=\"\\\$\{REF:-[^}]*\}\"|REF=\"\${REF:-$VERSION}\"|" \
  -e "s|^EXPECTED_SHA256=\"\\\$\{EXPECTED_SHA256:-[^}]*\}\"|EXPECTED_SHA256=\"\${EXPECTED_SHA256:-$SHA}\"|" \
  install.sh

# Stamp mint-token.sh: the default REF it prints in the install command.
sed -i -E \
  "s|^REF=\"\\\$\{REF:-[^}]*\}\"|REF=\"\${REF:-$VERSION}\"|" \
  server/scripts/mint-token.sh

echo "Stamped release $VERSION"
echo "  getdiskhealth.sh sha256: $SHA"
echo
echo "Next:"
echo "  git add -A"
echo "  git commit -m \"Release $VERSION\""
echo "  git tag $VERSION"
echo "  git push origin main $VERSION"
echo
echo "Devices then install with the printed mint-token.sh one-liner (pinned to $VERSION)."
