#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/add-changeset.sh <summary>

Creates an official-format Changesets fragment for Nehir.
Example:
  Scripts/add-changeset.sh "Fixed window restoration after display changes."
EOF
}

if [ "$#" -lt 1 ]; then
  usage
  exit 1
fi

SUMMARY="$*"
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
"nehir": patch
---

$SUMMARY
EOF

echo "Created ${FILE#$ROOT_DIR/}"
