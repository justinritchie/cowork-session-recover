#!/usr/bin/env bash
# resume.sh — print the exact iTerm command sequence to resume a session in Claude Code CLI,
# optionally with /compact applied.
#
# Usage:
#   resume.sh <session-uuid-or-prefix>          # prints resume command
#   resume.sh <session-uuid-or-prefix> compact  # prints resume + /compact sequence
#
# This script does NOT execute anything — it prints the commands so the calling Claude
# can drive iTerm with mcp__iterm-mcp__write_to_terminal.

set -euo pipefail

THIS="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-latest}"
MODE="${2:-resume}"

CHAT_UUID= ; PROJECT_CWD=
while IFS='=' read -r k v; do
  case "$k" in
    chat_uuid)   CHAT_UUID="$v" ;;
    project_cwd) PROJECT_CWD="$v" ;;
  esac
done < <("$THIS/locate.sh" "$ARG")

# IMPORTANT: For Cowork-created sessions, `claude --resume <uuid>` does NOT work —
# Claude Code's session-id registry doesn't index Cowork session JSONLs.
# `claude --continue` DOES work, because it walks the cwd's encoded project dir
# and resumes whatever JSONL is there. So we always cd to the session's
# original cwd and use --continue (no UUID needed).

case "$MODE" in
  resume)
    cat <<EOF
# Resume in Claude Code CLI (iTerm sequence)
cd "$PROJECT_CWD"
claude --continue
EOF
    ;;
  compact)
    cat <<EOF
# Compact-then-reopen sequence (iTerm)
# Step 1: open a CLI session at the broken chat (--continue picks up the JSONL in cwd)
cd "$PROJECT_CWD"
claude --continue

# Step 2: in the resumed Claude Code prompt, send the slash command:
/compact

# Step 3: wait for "Conversation compacted" confirmation, then exit:
/exit

# Step 4: try opening the session in Cowork again. If the session list still hangs,
# fully quit and relaunch the Claude desktop app — Cowork may cache the session list.
EOF
    ;;
  *)
    echo "ERROR: mode must be 'resume' or 'compact'" >&2
    exit 1
    ;;
esac
