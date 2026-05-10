---
name: cowork-session-recover
description: Recover a Cowork chat session whose UI won't open, has gone idle after auto-compaction, or is otherwise stuck. Trigger on phrases like "previous Cowork chat broke," "session won't load," "recover that chat from yesterday," "pick up where I left off," "use claude resume on X chat," "UI hangs when I open this conversation," "compact the broken session," "trim the JSONL," "session is too big to load." Reads the session's raw JSONL on disk (bypassing Cowork UI), diagnoses what state it's in, and offers three recovery modes — disk-side trim+replace so Cowork reopens the session in place, handoff brief for fresh start, or terminal resume via Claude Code CLI. Essential because Cowork's chat list can hang on sessions with large JSONL files (over 10MB) where the renderer chokes on parallel toolUseResult fields and base64 screenshots — only fix is to strip that bloat from the JSONL on disk before relaunching Cowork.
---

# Cowork session recovery

Use this skill when a Cowork chat session is unreachable from the Cowork UI (won't open, hangs the renderer, or shows an error) **or** when the user wants to deliberately hand off context from one long-running session to a fresh chat.

## When to trigger

- "Previous Cowork chat won't open"
- "The session [name/UUID] crashed/hangs/is broken"
- "Recover the [topic] chat from [date]"
- "Pick up where I left off in [session]"
- "Trim the JSONL so Cowork can load it"
- "Compact the broken session and try to reopen"
- "The session is too big to render"
- "Generate a handoff doc for [session]"

## Why sessions break — the actual root cause

Cowork (and Claude Code) stream every tool result, screenshot, and intermediate state into the session JSONL append-only. Once the assistant has already responded based on those payloads, the raw bytes are no longer load-bearing for resume — they're audit trail. But the renderer still has to parse them on session-open, which is what hangs the UI.

The biggest single offender is a **top-level `toolUseResult` field** Claude Code keeps in parallel with `message.content`. The model only sees `message.content`; `toolUseResult` is replay/audit data. On a long Cowork session it can be 10–200 KB per turn, easily 70%+ of the file. Nested base64 screenshots inside `tool_result.content` arrays are the second-biggest offender.

Stripping those two things alone typically takes a session from 25 MB to 7 MB without losing any conversation context. brtkwr.com's prune-history.sh script (production-validated against Claude Code logs) reports 88% reductions, with one extreme case going from 3.3 GB to 9.7 MB. We use the same patterns here.

## Where Cowork sessions live on disk

```
~/Library/Application Support/Claude/local-agent-mode-sessions/<workspace-uuid>/<account-uuid>/local_<session-uuid>/
├── audit.jsonl                           # harness telemetry (can be huge)
├── outputs/                              # files Claude wrote during the session
├── uploads/                              # files the user uploaded
└── .claude/projects/<encoded-path>/<chat-uuid>.jsonl   # the actual conversation
```

Two UUIDs matter:
- **session-uuid** (e.g., `local_xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) — the directory name on disk; what `mcp__session_info__list_sessions` returns
- **chat-uuid** (e.g., `yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy`) — the JSONL filename inside the session

## Decision tree

**Step 1.** Run `scripts/locate.sh <session-id-or-name-or-latest>` to find both UUIDs and the project working directory.

**Step 2.** Run `scripts/diagnose.sh <session-uuid>`. It prints turn counts, JSONL/audit log size, context fill %, compaction events, last user prompt verbatim, and files modified during the session.

**Step 3.** Run `scripts/repair_chain.py <jsonl> --analyze` to check for chain corruption (separate failure mode from size bloat). If it reports orphan parentUuid references, snapshot messageId collisions, or disconnected compaction roots, you have a chain-corruption problem on top of (or instead of) the size problem.

**Step 4.** Pick recovery modes — these are not mutually exclusive; you may run multiple:

| Diagnosis | Recommended mode |
|-----------|------------------|
| JSONL > 5 MB, Cowork UI hangs on open | **A. Trim + replace in place** (`scripts/recover.sh`) |
| Chain has orphans / collisions / disconnected roots, only first few turns visible on resume | **D. Repair parentUuid chain** (`scripts/repair_chain.py --fix-in-place`) |
| JSONL < 5 MB, conversation went well, just want fresh chat | **B. Handoff brief + new chat** (`scripts/handoff.sh`) |
| User wants to keep working in CLI, JSONL trim-able to <5 MB | **C. Trim + resume in Claude Code CLI** |

For severe cases, run **A then D then relaunch Cowork** — `recover.sh` does both in sequence automatically.

See README.md for full mode documentation, references, and citations.
