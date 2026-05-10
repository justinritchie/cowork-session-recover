# cowork-session-recover

Disk-side recovery for Cowork chat sessions whose UI hangs on open or shows only a fragment of the conversation on resume.

Claude Cowork (the new desktop research preview from Anthropic) is built on top of the Claude Code session model. Long sessions accumulate tool results, screenshots, and intermediate state in an append-only JSONL file. When that file gets large enough (typically 10+ MB), or when its `parentUuid` chain gets broken by one of several documented bugs, the Cowork UI starts to hang on session open and the chat list becomes unreliable. The session is intact on disk; the renderer just can't materialize it anymore.

This repository is the recovery toolkit. It's packaged as a Claude Code/Cowork skill (`.skill` file you install in the desktop app) plus a set of standalone scripts you can run from any terminal. It works on Cowork sessions specifically, but the underlying patterns are validated for plain Claude Code sessions too — the JSONL format is the same, just stored at a different path.

## What this fixes

Two separate failure modes:

**1. JSONL is too big — Cowork UI hangs on open.** The `toolUseResult` top-level field that Claude Code keeps as parallel raw tool output (in addition to `message.content` which is what the model actually sees) is usually 10-200 KB per turn, easily 70%+ of the file. Nested base64 screenshots inside `tool_result.content` arrays are the second-biggest offender. Stripping just those two things typically takes a session from 25 MB to 7 MB without losing any conversation context.

**2. `parentUuid` chain is corrupted — Cowork loads the session but only shows the last few turns.** Four documented bug classes break the chain walker: subagent sidechain UUIDs contaminate the main chain, `progress` entries reference UUIDs that were never flushed to disk, 403 retry storms re-emit user messages with wrong parents, and `/compact` creates new entries with `parentUuid: null` that strand earlier history. One reported session had 1,259 entries but only 199 were reachable from the last message — that's 84% of the conversation invisible to the renderer.

Both failure modes have the same root cause underneath: Cowork and Claude Code use an append-only on-disk format that wasn't designed for graceful degradation when things accumulate or get out of sync. The fix in both cases is disk-side surgery: read the JSONL, mutate it carefully, write it back, relaunch the app.

## Where Cowork stores sessions

```
~/Library/Application Support/Claude/local-agent-mode-sessions/
  <workspace-uuid>/
    <account-uuid>/
      local_<session-uuid>/
        audit.jsonl                          # harness telemetry, can be 70+ MB
        outputs/                             # files Claude wrote
        uploads/                             # files the user uploaded
        .claude/projects/<encoded-cwd>/
          <chat-uuid>.jsonl                  # the actual conversation
```

Claude Code stores its CLI sessions at `~/.claude/projects/<encoded-cwd>/<chat-uuid>.jsonl` instead. Same format, different path. This skill targets the Cowork path; if you only care about Claude Code, see [brtkwr/prune-history.sh](https://brtkwr.com/posts/2026-01-22-pruning-claude-code-conversation-history/) or [pchalasani/fix-session](https://pchalasani.github.io/claude-code-tools/tools/fix-session/) instead — they're more polished tools for that use case.

## Install

### As a Cowork/Claude Code skill

Download the latest `.skill` file from [releases](https://github.com/justinritchie/cowork-session-recover/releases) (or build it yourself with [skill-creator](https://github.com/anthropics/skills)) and install via Claude Desktop's plugin/skill installer. The skill auto-triggers on phrases like "previous Cowork chat won't open," "the session is too big to render," "trim the JSONL," "recover that broken chat."

### As standalone scripts

```bash
git clone https://github.com/justinritchie/cowork-session-recover.git
cd cowork-session-recover
chmod +x scripts/*.sh scripts/*.py
```

Dependencies: `bash`, `jq`, `python3` (3.8+). Tested on macOS; the scripts use `stat -f` (BSD) so Linux users will need a small tweak.

## Usage

### Quick path: just recover a broken session

```bash
./scripts/recover.sh <session-uuid-or-prefix>
```

This does the full pipeline: locate → backup → trim → atomic-replace → repair chain → print rollback command. After it runs, ⌘Q + relaunch Claude Desktop and try opening the session.

If you don't know the session UUID, find it in Cowork by right-clicking the session in the chat list → Copy URL. The URL looks like `https://claude.ai/local_sessions/local_<UUID>`. You can pass any unique prefix of the UUID.

### Diagnose first, then choose a recovery mode

```bash
./scripts/diagnose.sh <session-uuid>
```

Prints turn counts, JSONL/audit log size, context fill %, compaction events, last user prompt, files modified during the session, and a recommended recovery mode.

```bash
./scripts/repair_chain.py <jsonl-path> --analyze
```

Reports orphan parentUuid references, snapshot messageId collisions, and disconnected compaction roots. If any are non-zero, your session has chain corruption that trim alone won't fix.

### Mode A — Trim + replace in place (recovers Cowork UI)

What the `recover.sh` quick path does. Strips:

- The parallel `toolUseResult` field (biggest single source of bloat)
- Base64 images nested inside `tool_result.content` arrays (screenshots from chrome-devtools, iWDP, etc. — these slip past top-level image strips)
- The duplicated `normalizedMessages` field (Claude Code keeps this internally, identical to `message`)
- `thinking` blocks beyond a configurable cap
- `bash_progress.output` and `agent_progress.message` beyond cap
- Pure metadata records (`queue-operation`, `attachment`, `last-prompt`, `ai-title`)

Preserves intact:

- Every assistant text block (the actual reasoning and decisions)
- Every user prompt (intent)
- Tool_use blocks with truncated input bodies (so the conversation flow shape survives — turns still show "called Edit" / "called Bash")
- All structural metadata (`parentUuid`, `sessionId`, timestamps, version)

The model can still understand the conversation flow on resume. Tool result blobs are gone, but they were one-shot context for past decisions anyway.

You can also run the trim script directly with custom caps:

```bash
./scripts/trim_jsonl.py input.jsonl output.jsonl --max-tool-result 50 --max-tool-input 100
```

### Mode B — Handoff brief (fresh start in new Cowork chat)

When you don't need to revive the original session — you just want a fresh chat that knows where you left off:

```bash
./scripts/handoff.sh <session-uuid> ~/Desktop/handoff.md
```

Produces a markdown extract of the last 30 turns plus files modified plus the last user prompt. Then start a fresh Cowork chat with one line: `Read the handoff at <path> and let's continue.`

This is the safest mode — original Cowork JSONL untouched, new chat starts clean, full context preserved in a doc that future you can audit.

### Mode C — Resume in Claude Code CLI

Useful when the Cowork UI is fundamentally broken on a session and you'd rather work in the terminal.

**Important gotcha:** `claude --resume <chat-uuid>` does NOT find Cowork sessions by default. Claude Code's session-id registry indexes JSONLs in `~/.claude/projects/`, but Cowork stores them at `~/Library/Application Support/Claude/local-agent-mode-sessions/.../`. The workaround that works:

```bash
# 1. Trim first so the JSONL is CLI-loadable (the TUI also chokes on >25 MB)
./scripts/recover.sh <session-uuid>

# 2. Find Claude Code's project dir for the session's cwd
ls ~/.claude/projects/ | grep "$(echo "$session_cwd" | tr / -)"

# 3. Copy the trimmed Cowork JSONL into Claude Code's project dir
cp <cowork-jsonl> "$HOME/.claude/projects/<encoded-cwd>/<chat-uuid>.jsonl"

# 4. cd to the original cwd and resume
cd "<original-cwd>"
claude --resume <chat-uuid>
```

Verified end-to-end against a 5,388-record Cowork session (after trim).

### Mode D — Repair parentUuid chain

```bash
./scripts/repair_chain.py <jsonl-path> --analyze        # diagnose only
./scripts/repair_chain.py <jsonl-path> --fix-in-place  # repair (creates .bak)
```

Fixes three bug classes:

1. **Orphan parentUuid references** — relinks to the nearest valid predecessor by file position
2. **Snapshot messageId collisions** — sets the colliding `file-history-snapshot.messageId` to null
3. **Disconnected compaction roots** — connects `parentUuid: null` entries (after the first) to the preceding real entry

`recover.sh` runs this automatically after `trim_jsonl.py`, since trim itself drops some records that other turns reference as parents — running both in sequence is the validated recovery path.

## Trade-offs and caveats

**Trim invalidates the prompt cache.** Claude Code uses `cache_control` breakpoints to bill repeated context at ~10% of base price. Trimming `toolUseResult` records and tool result content rewrites the cached prefix from that point forward, so the first resumed turn after a trim pays full price to re-cache everything. For a recovery scenario this is the right trade-off — getting access to the session matters more than one expensive turn — but don't run `recover.sh` as routine maintenance on healthy sessions.

**Backups are your friend.** Both `recover.sh` and `repair_chain.py --fix-in-place` write a `.bak-<UTC-timestamp>` next to the original before mutating. Don't delete it until you've confirmed the trimmed/repaired session loads correctly and shows the full conversation. Rollback is one command:

```bash
cp <jsonl>.bak-<timestamp> <jsonl>
```

**Subagent sidechains live in separate files.** If your broken session spawned subagents, those have their own JSONLs at sibling project directories. This skill operates on the main JSONL only — chain references into sidechain UUIDs don't get rewritten. If your session relies heavily on subagents, expect partial recovery.

**This is a research-preview-grade tool.** Cowork is brand new (Q2 2026 research preview). The internal JSONL format will evolve. The strip patterns this skill uses are validated against the format as of skill version 0.1; future Cowork updates may introduce new bulk-payload fields that need to be added to the strip list. If you find one, PRs welcome.

## Validation

The underlying patterns this skill uses are validated for Claude Code (CLI) sessions through several production tools:

- [brtkwr.com/posts/2026-01-22-pruning-claude-code-conversation-history](https://brtkwr.com/posts/2026-01-22-pruning-claude-code-conversation-history/) reports 88% size reductions across many sessions, one extreme case 3.3 GB → 9.7 MB.
- [pchalasani's fix-session](https://pchalasani.github.io/claude-code-tools/tools/fix-session/) is a published CLI tool with `make` integration and dry-run mode for the parentUuid repair case.
- [tennox's gist](https://gist.github.com/tennox/90ef5c803ec4b64c9fbba0f71ca1ae2e) is a Nushell script for collision/orphan repair, referenced in Claude Code GitHub issue #24304 with confirmed user testing.

For Cowork specifically: this skill is at the frontier. I haven't found anyone publicly documenting Cowork-session surgery. The application of validated Claude Code patterns to Cowork's storage path is novel as far as I know, but the underlying file format is shared, so the techniques transfer cleanly. If you're hitting this and have results to share, open an issue.

## Prior art and citations

### Trimming and pruning

- **brtkwr.com prune-history.sh** ([blog post](https://brtkwr.com/posts/2026-01-22-pruning-claude-code-conversation-history/)) — production-validated jq script. 88% size reductions, the cornerstone reference. We copied the field-strip list (`normalizedMessages`, `toolUseResult`, `bash_progress`, `thinking` blocks).
- **OpenClaw memory model** ([Velvetshark masterclass](https://velvetshark.com/openclaw-memory-masterclass)) — defines the "pruning" (lossless, in-memory) vs "compaction" (lossy, summarization) distinction that frames our skill's design.
- **LangChain Deep Agents** ([blog](https://www.langchain.com/blog/context-management-for-deepagents)) — offload large tool inputs/outputs to filesystem at 85% threshold. Inspired the size-based mode recommendations.
- **Claude Code architecture analysis** ([Bits Bytes and Neural Networks](https://bits-bytes-nn.github.io/insights/agentic-ai/2026/03/31/claude-code-architecture-analysis.html)) — documents the five-layer in-app compression pipeline (tool result budget → snip → microcompact → context collapse → auto-compact) and the cache-aware microcompact pattern. Our recovery skill operates at the disk layer below all of these.
- **Claude Code session/compact docs** ([Mintlify mirror](https://www.mintlify.com/sanbuphy/claude-code-source-code/reference/commands/session-management)) — lifecycle reference for `/compact`, `/clear`, microcompact, and context collapse.
- **"Inside Claude Code: The Session File Format"** ([databunny on Medium](https://databunny.medium.com/inside-claude-code-the-session-file-format-and-how-to-inspect-it-b9998e66d56b)) — clean walkthrough of what's in the JSONL and how it links together. Useful reference for understanding the records we mutate.
- **"Dive into Claude Code"** ([arxiv 2604.14228](https://arxiv.org/html/2604.14228v1)) — academic paper documenting Claude Code's design space, including the compaction pipeline and sidechain transcript structure.

### Chain repair

- **fix-session by pchalasani** ([docs](https://pchalasani.github.io/claude-code-tools/tools/fix-session/)) — a CLI tool that does the same orphan repair we ship as `repair_chain.py`. Worth installing as a standalone if you want a more polished alternative for Claude Code sessions.
- **tennox's gist** ([gist](https://gist.github.com/tennox/90ef5c803ec4b64c9fbba0f71ca1ae2e)) — Nushell script that detects + fixes snapshot messageId collisions and broken parentUuid references. The two-bug-class framing came from here.
- **cacheoverflow.dev orphan repair** ([blog](https://cacheoverflow.dev/blog/u-0oY5DW)) — Python script we modeled `repair_chain.py` after.

### Documented bugs

These are the upstream Claude Code GitHub issues that motivate this skill's existence:

- [#19443](https://github.com/anthropics/claude-code/issues/19443) — `/compact` times out at 60s on 41 MB JSONLs and corrupts session state. Why we trim on disk instead of trying to drive `/compact` on a broken session.
- [#22365](https://github.com/anthropics/claude-code/issues/22365) — 3.8 GB JSONL files cause Claude Code to hang and consume all available RAM. Confirms the size-bloat failure mode.
- [#24304](https://github.com/anthropics/claude-code/issues/24304) — "Conversation history missing on resume" — orphan parentUuid breaks chain walker.
- [#35024](https://github.com/anthropics/claude-code/issues/35024) — progress entries create parasitic forks in parentUuid chain, losing 80%+ of conversation.
- [#37437](https://github.com/anthropics/claude-code/issues/37437) — session resume after 403 retry breaks parentUuid chain.
- [#46603](https://github.com/anthropics/claude-code/issues/46603) — context compaction creates new messages with parentUuid references that don't exist in the JSONL.

All four chain-corruption bugs (#24304, #35024, #37437, #46603) produce the same symptom — resume only shows 4-17% of conversation. Mode D addresses all four.

### Manual handoff and continuity patterns

- **HN thread on letter-to-self** ([HN 47240336](https://news.ycombinator.com/item?id=47240336)) — manual technique where users explicitly ask Claude to write a letter to its future self before compaction. Better summaries than auto-compact's brief default prompt. Our Mode B handoff is essentially this, automated.
- **Claude Cookbook session memory compaction** ([cookbook](https://platform.claude.com/cookbook/misc-session-memory-compaction)) — patterns for instant background compaction with cache-aware reuse.
- **Forky / Context Branching for LLM Conversations** ([arxiv 2512.13914](https://arxiv.org/html/2512.13914v1)) — Git-style fork/merge for conversations, 13.2% improvement, 58.1% context reduction. Future direction; not currently implemented in this skill.
- **18 Claude Code Token Management Hacks** ([MindStudio blog](https://www.mindstudio.ai/blog/claude-code-token-management-hacks/)) — practical guidance on session-handoff notes and proactive compaction.

### Atomic write protection

- **cozempic** (referenced in [#37437 comments](https://github.com/anthropics/claude-code/issues/37437)) — an open-source Claude Code wrapper that uses atomic writes (write→fsync→replace) to prevent partial-write corruption during resume. We adopted this pattern in `recover.sh`.

## Contributing

Issues and PRs welcome. Particularly useful contributions:

- **More strip patterns.** Cowork's JSONL format will evolve. If you find a new bulk-payload field that's safe to strip, add it to `trim_jsonl.py` with a comment explaining what it is.
- **Linux compatibility.** The shell scripts use `stat -f` (BSD/macOS); Linux users need `stat -c %s` instead. A compatibility shim would be welcome.
- **Cowork validation results.** If you've used this on a real broken Cowork session, share the before/after numbers and whether the UI loaded after recovery. We're still building the empirical record for Cowork specifically.
- **Subagent sidechain handling.** Currently the skill only operates on the main JSONL. Walking subagent JSONLs (which live in sibling project directories) and repairing cross-file chain references would make the skill robust against subagent-heavy sessions.

## License

MIT. Use it, fork it, ship it.

## Acknowledgments

The skill structure follows Anthropic's [skill-creator](https://github.com/anthropics/skills) conventions. Thanks to brtkwr, pchalasani, and tennox specifically — without their published prior work on Claude Code session repair, this skill would be a lot harder to validate.
