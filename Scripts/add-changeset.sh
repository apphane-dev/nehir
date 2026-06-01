#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/add-changeset.sh <type> <summary>

Types: added, changed, fixed, removed, security, internal
Example:
  Scripts/add-changeset.sh fixed "Fixed window restoration after display changes."
EOF
}

if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

TYPE="$1"
shift
SUMMARY="$*"

case "$TYPE" in
  added|changed|fixed|removed|security|internal) ;;
  *)
    echo "Invalid changeset type: $TYPE" >&2
    usage
    exit 1
    ;;
esac

if [ -z "$SUMMARY" ]; then
  echo "Summary must not be empty." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT_DIR/.changeset"

SLUG="$(printf '%s' "$SUMMARY" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
  | cut -c1-48)"
[ -n "$SLUG" ] || SLUG="change"

FILE="$ROOT_DIR/.changeset/$(date +%Y%m%d%H%M%S)-$SLUG.md"
cat > "$FILE" <<EOF
---
type: $TYPE
---

$SUMMARY
EOF

echo "Created ${FILE#$ROOT_DIR/}"
