#!/usr/bin/env bash
# locate.sh — find a Cowork session's directory + JSONL on disk
# Usage:
#   locate.sh <session-uuid-or-prefix>
#   locate.sh latest          # most recent session by mtime
#   locate.sh latest-idle     # most recent session that's not the currently-running one
#
# Prints (one per line, key=value):
#   session_dir=<absolute path>
#   chat_uuid=<uuid>
#   jsonl_path=<absolute path>
#   audit_path=<absolute path>
#   project_cwd=<the working directory the session was started in, from the JSONL>
#   resume_command=<copy-paste claude --resume command>

set -euo pipefail

ROOT="$HOME/Library/Application Support/Claude/local-agent-mode-sessions"
[ -d "$ROOT" ] || { echo "ERROR: Cowork session root not found at $ROOT" >&2; exit 1; }

ARG="${1:-latest}"

find_session_dir() {
  local query="$1"
  if [ "$query" = "latest" ] || [ "$query" = "latest-idle" ]; then
    # Find most recently modified local_* dir
    find "$ROOT" -maxdepth 4 -type d -name 'local_*' -print0 \
      | xargs -0 stat -f '%m %N' 2>/dev/null \
      | sort -rn | awk '{ $1=""; sub(/^ /,""); print; exit }'
  else
    # Strip 'local_' if user pasted full name; allow prefix matching
    local q="${query#local_}"
    find "$ROOT" -maxdepth 4 -type d -name "local_${q}*" 2>/dev/null | head -1
  fi
}

SESSION_DIR=$(find_session_dir "$ARG")
[ -n "$SESSION_DIR" ] || { echo "ERROR: no session matching '$ARG'" >&2; exit 2; }

JSONL=$(find "$SESSION_DIR/.claude/projects" -maxdepth 3 -name '*.jsonl' 2>/dev/null | head -1)
[ -n "$JSONL" ] || { echo "ERROR: no JSONL inside $SESSION_DIR" >&2; exit 3; }

CHAT_UUID=$(basename "$JSONL" .jsonl)
AUDIT="$SESSION_DIR/audit.jsonl"

# Pull the working directory from the first system message in the JSONL (Claude Code stores cwd there)
PROJECT_CWD=$(jq -r 'select(.type=="system" and .cwd) | .cwd' "$JSONL" 2>/dev/null | head -1)
if [ -z "$PROJECT_CWD" ] || [ "$PROJECT_CWD" = "null" ]; then
  # Fallback: decode from the encoded directory name
  ENCODED=$(basename "$(dirname "$JSONL")")
  PROJECT_CWD=$(echo "$ENCODED" | sed 's/^-//; s/-/\//g' | sed 's|^|/|')
fi

cat <<EOF
session_dir=$SESSION_DIR
chat_uuid=$CHAT_UUID
jsonl_path=$JSONL
audit_path=$AUDIT
project_cwd=$PROJECT_CWD
resume_command=cd "$PROJECT_CWD" && claude --continue
EOF
