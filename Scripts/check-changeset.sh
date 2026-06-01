#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
  if python3 - "${GITHUB_EVENT_PATH:-}" <<'PY'
import json
import sys
from pathlib import Path

event_path = sys.argv[1]
if not event_path:
    raise SystemExit(1)

data = json.loads(Path(event_path).read_text())
labels = {label.get("name", "").lower() for label in data.get("pull_request", {}).get("labels", [])}
raise SystemExit(0 if "no release note" in labels else 1)
PY
  then
    echo "Skipping changeset check because PR has the 'no release note' label."
    exit 0
  fi
fi

if git log -1 --pretty=%B | grep -qi '\[skip changeset\]'; then
  echo "Skipping changeset check because commit message contains [skip changeset]."
  exit 0
fi

if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
  git fetch --no-tags --depth=1 origin "$GITHUB_BASE_REF" >/dev/null 2>&1 || true
  BASE="origin/$GITHUB_BASE_REF"
elif git rev-parse HEAD^ >/dev/null 2>&1; then
  BASE="HEAD^"
else
  echo "No base commit available; skipping changeset check."
  exit 0
fi

CHANGED="$(git diff --name-only "$BASE"...HEAD 2>/dev/null || git diff --name-only "$BASE" HEAD)"
if [ -z "$CHANGED" ]; then
  echo "No changed files."
  exit 0
fi

if printf '%s\n' "$CHANGED" | grep -Eq '^(\.changeset/[^/]+\.md|docs/releases/v[0-9][^/]*\.md)$'; then
  echo "Changeset or release notes present."
  exit 0
fi

if printf '%s\n' "$CHANGED" | grep -Eq '^(Sources/|Resources/|Info\.plist$|Package\.swift$|Package\.resolved$|Nehir\.entitlements$)'; then
  cat >&2 <<'EOF'
User-visible files changed, but no changeset was added.

Add one with:
  Scripts/add-changeset.sh fixed "Describe the user-visible change."

If this PR truly has no release-note impact, add the GitHub label: no release note
For non-PR commits, include [skip changeset] in the commit message.
EOF
  exit 1
fi

echo "No changeset required for changed paths."
