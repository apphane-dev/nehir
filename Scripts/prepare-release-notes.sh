#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: Scripts/prepare-release-notes.sh <version>" >&2
  echo "Example: Scripts/prepare-release-notes.sh 0.2.1" >&2
  exit 1
fi

VERSION="$1"
TAG="v${VERSION#v}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGESET_DIR="$ROOT_DIR/.changeset"
RELEASE_DIR="$ROOT_DIR/docs/releases"
NOTES_FILE="$RELEASE_DIR/$TAG.md"
ARCHIVE_DIR="$RELEASE_DIR/changesets/$TAG"

python3 - "$CHANGESET_DIR" "$NOTES_FILE" "$ARCHIVE_DIR" "$TAG" <<'PY'
from pathlib import Path
import re
import shutil
import sys

changeset_dir = Path(sys.argv[1])
notes_file = Path(sys.argv[2])
archive_dir = Path(sys.argv[3])
tag = sys.argv[4]

headings = {
    "added": "Added",
    "changed": "Changed",
    "fixed": "Fixed",
    "removed": "Removed",
    "security": "Security",
    "internal": "Internal",
}
order = ["added", "changed", "fixed", "removed", "security", "internal"]
entries = {key: [] for key in order}
files = sorted(p for p in changeset_dir.glob("*.md") if p.name.upper() != "README.MD")

if not files:
    raise SystemExit("No pending changesets found in .changeset/*.md")

pattern = re.compile(r"^---\s*\ntype:\s*([a-z]+)\s*\n---\s*\n(.*)$", re.S)
for path in files:
    text = path.read_text().strip()
    match = pattern.match(text)
    if not match:
        raise SystemExit(f"Invalid changeset format: {path}")
    kind, body = match.group(1), match.group(2).strip()
    if kind not in entries:
        raise SystemExit(f"Invalid changeset type in {path}: {kind}")
    if not body:
        raise SystemExit(f"Empty changeset body: {path}")
    normalized = " ".join(line.strip() for line in body.splitlines() if line.strip())
    entries[kind].append(normalized)

lines = [f"# Nehir {tag[1:]}", ""]
for kind in order:
    if not entries[kind]:
        continue
    lines += [f"## {headings[kind]}", ""]
    for item in entries[kind]:
        prefix = "- " if not item.startswith("- ") else ""
        lines.append(f"{prefix}{item}")
    lines.append("")

lines += [
    "## Notes",
    "",
    "Nehir is currently distributed as an unsigned app. macOS may show Gatekeeper warnings until Developer ID signing and notarization are configured.",
    "",
    "Nehir requires Accessibility permission to manage windows.",
    "",
]

notes_file.parent.mkdir(parents=True, exist_ok=True)
if notes_file.exists():
    raise SystemExit(f"Release notes already exist: {notes_file}")
notes_file.write_text("\n".join(lines))

archive_dir.mkdir(parents=True, exist_ok=True)
for path in files:
    target = archive_dir / path.name
    if target.exists():
        raise SystemExit(f"Archive target already exists: {target}")
    shutil.move(str(path), str(target))

print(f"Created {notes_file}")
print(f"Archived {len(files)} changeset(s) to {archive_dir}")
PY
