#!/usr/bin/env bash
# diagnose.sh — print a structured diagnosis of a Cowork session's JSONL
# Usage:
#   diagnose.sh <session-uuid-or-prefix>
#
# Outputs a markdown-friendly diagnosis suitable for the user to read directly,
# plus a final "RECOMMENDATION:" line that the skill can parse.

set -euo pipefail

THIS="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-latest}"

# Parse locate.sh's key=value output into shell vars (preserves spaces in values)
JSONL= ; CHAT_UUID= ; SESSION_DIR= ; AUDIT= ; PROJECT_CWD=
while IFS='=' read -r k v; do
  case "$k" in
    jsonl_path)   JSONL="$v" ;;
    chat_uuid)    CHAT_UUID="$v" ;;
    session_dir)  SESSION_DIR="$v" ;;
    audit_path)   AUDIT="$v" ;;
    project_cwd)  PROJECT_CWD="$v" ;;
  esac
done < <("$THIS/locate.sh" "$ARG")

JSONL_LINES=$(wc -l < "$JSONL" | tr -d ' ')
JSONL_BYTES=$(stat -f %z "$JSONL" 2>/dev/null || stat -c %s "$JSONL")
AUDIT_BYTES=$([ -f "$AUDIT" ] && stat -f %z "$AUDIT" 2>/dev/null || echo 0)
AUDIT_MB=$(( AUDIT_BYTES / 1024 / 1024 ))

ASST_TURNS=$(jq -r 'select(.type=="assistant") | 1' "$JSONL" 2>/dev/null | wc -l | tr -d ' ')
USER_TURNS=$(jq -r 'select(.type=="user") | 1' "$JSONL" 2>/dev/null | wc -l | tr -d ' ')
COMPACTIONS=$(jq -c 'select(.subtype=="compact_boundary")' "$JSONL" 2>/dev/null | wc -l | tr -d ' ')

# Max cache_read across the session = effective context fill
MAX_CTX=$(jq -r 'select(.type=="assistant" and .message.usage.cache_read_input_tokens) | .message.usage.cache_read_input_tokens' "$JSONL" 2>/dev/null | sort -n | tail -1)
MAX_CTX=${MAX_CTX:-0}
CTX_PCT=$(( MAX_CTX * 100 / 1000000 ))

# Last assistant timestamp + last user prompt
LAST_TS=$(jq -r 'select(.type=="assistant" and .timestamp) | .timestamp' "$JSONL" 2>/dev/null | tail -1)
LAST_PROMPT=$(jq -r 'select(.type=="last-prompt") | .lastPrompt' "$JSONL" 2>/dev/null | tail -1)
[ -z "$LAST_PROMPT" ] && LAST_PROMPT=$(jq -r 'select(.type=="user" and (.message.content | type == "string")) | .message.content' "$JSONL" 2>/dev/null | tail -1)

# Stop-reason distribution
STOPS=$(jq -r 'select(.type=="assistant" and .message.stop_reason) | .message.stop_reason' "$JSONL" 2>/dev/null | sort | uniq -c | awk '{printf "%s:%s ", $2, $1}')

# Files modified by Edit/Write/MultiEdit tool_use blocks
FILES_TOUCHED=$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and (.name=="Edit" or .name=="Write" or .name=="MultiEdit" or .name=="NotebookEdit")) | .input.file_path' "$JSONL" 2>/dev/null | sort -u | head -20)

cat <<EOF
# Cowork session diagnosis

**Session:** $(basename "$SESSION_DIR")
**Chat UUID:** $CHAT_UUID
**Project cwd:** $PROJECT_CWD
**JSONL:** $JSONL_LINES lines, $(( JSONL_BYTES / 1024 )) KB
**Audit log:** ${AUDIT_MB} MB

## Activity

- Assistant turns: $ASST_TURNS
- User turns: $USER_TURNS
- Compaction events: $COMPACTIONS
- Last assistant turn: ${LAST_TS:-unknown}
- Stop reasons: ${STOPS:-none recorded}

## Context size

- Peak \`cache_read_input_tokens\`: $MAX_CTX (~${CTX_PCT}% of 1M-token Opus window)

## Last user prompt (verbatim)

> ${LAST_PROMPT:-(none captured)}

## Files modified during the session

$(echo "$FILES_TOUCHED" | sed 's/^/- /')

## Resume command (Claude Code CLI — use --continue, NOT --resume)

\`\`\`bash
cd "$PROJECT_CWD" && claude --continue
\`\`\`

> Note: \`claude --resume $CHAT_UUID\` will fail with "No conversation found" because Claude Code's session-ID registry doesn't index Cowork-stored JSONLs. \`--continue\` from the right cwd does work — it walks the encoded project dir and resumes the JSONL there.

EOF

# --- Recommendation logic ---
REC="A_handoff"
REASON="default"

if [ "$CTX_PCT" -lt 60 ] && [ "$AUDIT_MB" -lt 50 ]; then
  REC="B_resume"
  REASON="context healthy ($CTX_PCT%), audit log moderate (${AUDIT_MB}MB)"
elif [ "$CTX_PCT" -lt 90 ] || [ "$AUDIT_MB" -lt 100 ]; then
  REC="C_compact"
  REASON="context elevated ($CTX_PCT%) or audit log heavy (${AUDIT_MB}MB) — try compacting via CLI before opening in Cowork"
else
  REC="A_handoff"
  REASON="context very full ($CTX_PCT%) or audit log very heavy (${AUDIT_MB}MB) — fresh start with handoff brief is safest"
fi

cat <<EOF
## Recommendation

**Mode:** $REC
**Why:** $REASON

RECOMMENDATION: $REC
EOF
