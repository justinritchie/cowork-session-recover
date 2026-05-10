#!/usr/bin/env bash
# handoff.sh — extract a session's last-N turns into a markdown handoff brief.
# This script does the EXTRACTION; the calling Claude turn does the SUMMARIZATION
# (reads the extract, writes a clean brief at OUT_PATH).
#
# Usage:
#   handoff.sh <session-uuid-or-prefix> [last-n-turns] [out-path]
# Defaults: last-n-turns=30, out-path=~/Desktop/session-handoff-<title>-<YYYY-MM-DD>.md
#
# Output: prints both
#   1. The raw last-N turns extract (for Claude to summarize)
#   2. A header with the suggested OUT_PATH and a template for Claude to fill in

set -euo pipefail

THIS="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-latest}"
LAST_N="${2:-30}"
OUT_PATH="${3:-}"

JSONL= ; CHAT_UUID= ; SESSION_DIR= ; PROJECT_CWD=
while IFS='=' read -r k v; do
  case "$k" in
    jsonl_path)   JSONL="$v" ;;
    chat_uuid)    CHAT_UUID="$v" ;;
    session_dir)  SESSION_DIR="$v" ;;
    project_cwd)  PROJECT_CWD="$v" ;;
  esac
done < <("$THIS/locate.sh" "$ARG")

# Best-effort title slug for the output filename
TITLE=$(jq -r 'select(.type=="ai-title" and .aiTitle) | .aiTitle' "$JSONL" 2>/dev/null | tail -1)
[ -z "$TITLE" ] && TITLE=$(basename "$SESSION_DIR" | sed 's/^local_//')
SLUG=$(echo "$TITLE" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-60)
DATE=$(date +%Y-%m-%d)

if [ -z "$OUT_PATH" ]; then
  OUT_PATH="$HOME/Desktop/session-handoff-${SLUG}-${DATE}.md"
fi

# Extract the last N turns as plain text, with role markers
EXTRACT=$(jq -r '
  select(.type=="user" or .type=="assistant") |
  if .type == "user" then
    if (.message.content | type) == "string" then
      "[USER] " + (.message.content | tostring)
    else
      "[USER tool_result] " + ((.message.content // []) | map(.content // .) | tostring | .[0:300])
    end
  elif .type == "assistant" then
    .message.content[]? |
    if .type == "text" then
      "[ASSISTANT] " + .text
    elif .type == "tool_use" then
      "[ASSISTANT tool_use=" + .name + "] " + (.input | tostring | .[0:300])
    else empty end
  else empty end
' "$JSONL" 2>/dev/null | tail -$(( LAST_N * 4 )))   # ~4 blocks per turn

# Files modified
FILES=$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and (.name=="Edit" or .name=="Write" or .name=="MultiEdit")) | .input.file_path' "$JSONL" 2>/dev/null | sort -u)

# Last user prompt verbatim
LAST_PROMPT=$(jq -r 'select(.type=="last-prompt") | .lastPrompt' "$JSONL" 2>/dev/null | tail -1)

cat <<EOF
=== HANDOFF EXTRACT (for Claude to summarize into the brief at $OUT_PATH) ===

Session title: $TITLE
Project cwd: $PROJECT_CWD
Chat UUID: $CHAT_UUID

--- Files modified during the session ---
$FILES

--- Last user prompt verbatim ---
$LAST_PROMPT

--- Last $LAST_N turns (raw extract) ---
$EXTRACT

=== END EXTRACT ===

INSTRUCTIONS FOR CLAUDE:
Write a handoff brief to: $OUT_PATH
Use this template:

# Session handoff: $TITLE

**Original session:** $(basename "$SESSION_DIR")
**Chat UUID:** $CHAT_UUID
**Working directory:** $PROJECT_CWD
**Generated:** $(date "+%Y-%m-%d %H:%M %Z")

## What we were doing
[3-5 sentences synthesized from the extract above]

## Last decisions made
[Bulleted list of the user's last 5 substantive instructions and what each one targeted]

## Files modified
[The files listed above, with a one-line note per file about what changed]

## Open thread
[The user's last unanswered or partially-answered prompt, verbatim, and what the model was working on when the session went idle]

## To pick up in a new chat
Paste this in a fresh Cowork chat:

> Read the handoff at $OUT_PATH and let's continue. The last thing we landed was [short summary]. Now I want to [user's next intent if discernible, otherwise: ask the user].
EOF
