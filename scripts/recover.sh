#!/usr/bin/env bash
# recover.sh — full Cowork session recovery: backup + trim + replace + repair chain.
# Use this when the Cowork UI hangs trying to open a session and you want
# to make the session loadable again in place.
#
# Usage:
#   recover.sh <session-uuid-or-prefix> [--max-tool-result CHARS] [--keep-images]
#
# Steps:
#   1. Locate the session JSONL via locate.sh
#   2. Back up the original to <jsonl>.bak-<UTC-timestamp>
#   3. Run trim_jsonl.py to strip toolUseResult / images / metadata bloat
#   4. Atomic-replace the original with the trimmed version (mv, not cp)
#   5. Run repair_chain.py to fix orphan parentUuids created by the trim
#   6. Print the path of the backup for rollback if needed

set -euo pipefail

THIS="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-latest}"
shift || true
TRIM_ARGS="$*"

# Locate the session
JSONL=
while IFS='=' read -r k v; do
  case "$k" in
    jsonl_path) JSONL="$v" ;;
  esac
done < <("$THIS/locate.sh" "$ARG")

[ -n "$JSONL" ] || { echo "ERROR: could not locate session for '$ARG'" >&2; exit 1; }
[ -f "$JSONL" ] || { echo "ERROR: JSONL not found at $JSONL" >&2; exit 1; }

ORIG_BYTES=$(stat -f %z "$JSONL" 2>/dev/null || stat -c %s "$JSONL")
ORIG_MB=$(awk "BEGIN { printf \"%.2f\", $ORIG_BYTES / 1024 / 1024 }")

echo "=== Cowork session recovery ==="
echo "Target JSONL: $JSONL"
echo "Original size: $ORIG_MB MB"

# Back up
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BAK="${JSONL}.bak-$STAMP"
cp "$JSONL" "$BAK"
echo "Backup: $BAK"

# Trim into a temp file
TMPDIR=$(mktemp -d)
TRIMMED="$TMPDIR/$(basename "$JSONL")"
python3 "$THIS/trim_jsonl.py" "$JSONL" "$TRIMMED" $TRIM_ARGS
NEW_BYTES=$(stat -f %z "$TRIMMED" 2>/dev/null || stat -c %s "$TRIMMED")
NEW_MB=$(awk "BEGIN { printf \"%.2f\", $NEW_BYTES / 1024 / 1024 }")
PCT=$(awk "BEGIN { printf \"%.0f\", (1 - $NEW_BYTES / $ORIG_BYTES) * 100 }")

# Atomic replace: write next to the original then mv (rename is atomic on POSIX)
# Pattern borrowed from cozempic (referenced in claude-code issue #37437) — prevents
# partial-write corruption if the process is interrupted mid-replace, which would
# leave the JSONL in a state Cowork can't even parse.
NEXT_TO="${JSONL}.new-$STAMP"
cp "$TRIMMED" "$NEXT_TO"
mv "$NEXT_TO" "$JSONL"
rm -rf "$TMPDIR"

# Trim drops metadata records (queue-operation, attachment, etc.) whose UUIDs are
# referenced as parentUuid by real assistant/user turns. This creates orphan
# parentUuid references — the renderer would only show entries reachable from
# the last leaf. Auto-repair to relink orphans to nearest valid predecessors.
echo
echo "=== Auto-repair chain integrity (orphans created by trim) ==="
python3 "$THIS/repair_chain.py" "$JSONL" --fix-in-place 2>&1 | grep -v DeprecationWarning

echo
echo "=== Recovery complete ==="
echo "Original:  $ORIG_MB MB"
echo "Trimmed:   $NEW_MB MB ($PCT% reduction)"
echo "Backup at: $BAK"
echo
echo "Next steps:"
echo "  1. ⌘Q + relaunch Claude Desktop so Cowork re-reads the JSONL"
echo "  2. Open the session in Cowork and see if the UI loads"
echo "  3. If it still hangs, run recover.sh again with a smaller cap, e.g.:"
echo "       recover.sh $ARG --max-tool-result 50"
echo "  4. To roll back at any time:"
echo "       cp \"$BAK\" \"$JSONL\""
