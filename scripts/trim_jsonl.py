#!/usr/bin/env python3
"""Trim a Cowork / Claude Code session JSONL by stripping bloat that's dead
weight at recovery time. Preserves conversation flow (user prompts + assistant
text + tool_use shape) while gutting the raw payloads behind them.

Background: Cowork and Claude Code stream every tool result, screenshot, and
intermediate state into the session JSONL append-only. Once the assistant has
already responded based on those payloads, the raw bytes are no longer load-
bearing for resume — they're audit trail. But the renderer (Cowork UI / Claude
Code TUI) still has to parse them on session-open, which is what hangs the UI
on multi-MB sessions.

Validated patterns (all from production session-pruning scripts in the wild):
- brtkwr.com prune-history.sh — reports 88% size reductions, 3.3 GB → 9.7 MB
- OpenClaw "pruning vs compaction" model — pruning is the lossless half
- LangChain Deep Agents offload-at-85% pattern
- Mintlify Claude Code "microcompact" docs

What we cut:
1. `toolUseResult` top-level field (parallel raw tool output, often 10-200 KB
   per record; biggest single source of bloat)
2. Nested base64 images inside tool_result.content arrays (screenshots — these
   slip past the top-level image strip)
3. `normalizedMessages` field (duplicate of `message` Claude Code keeps internally)
4. `thinking` blocks beyond a cap (extended reasoning, often kilobytes each)
5. `bash_progress.output` beyond a cap (long command output)
6. `agent_progress.message` beyond a cap (subagent fanout state)
7. Top-level images in user messages
8. Pure-metadata records (`queue-operation`, `attachment`, `last-prompt`,
   `ai-title`) — the renderer doesn't need them after the session is done

What we KEEP intact:
- Every assistant text block (the actual reasoning/decisions)
- Every user prompt (intent)
- Tool_use blocks (with truncated input bodies) so the conversation flow shape
  survives — assistant turns still show "called Edit" / "called Bash" etc.
- All structural metadata (parentUuid, sessionId, timestamps, version)

Usage:
    trim_jsonl.py <input.jsonl> <output.jsonl> [--max-tool-result CHARS] [--max-tool-input CHARS]
"""
import argparse, copy, json, sys

ap = argparse.ArgumentParser()
ap.add_argument('infile')
ap.add_argument('outfile')
ap.add_argument('--max-tool-result', type=int, default=150,
                help='Cap each tool_result / toolUseResult / thinking block at this many chars (default: 150)')
ap.add_argument('--max-tool-input', type=int, default=200,
                help='Cap each tool_use input body field at this many chars (default: 200)')
ap.add_argument('--keep-images', action='store_true',
                help='Do not strip base64 images')
args = ap.parse_args()

MAX_TR = args.max_tool_result
MAX_TI = args.max_tool_input
DROP_IMAGES = not args.keep_images

kept = trimmed = dropped = 0
out_bytes = 0


def truncate_str(s, cap, label='truncated'):
    if isinstance(s, str) and len(s) > cap:
        return s[:cap] + f'\n...[{label} {len(s) - cap} chars]'
    return s


with open(args.infile) as f, open(args.outfile, 'w') as g:
    for line in f:
        line = line.rstrip('\n')
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        rtype = rec.get('type')

        # Drop bulk-only metadata records the renderer doesn't need at recovery
        if rtype in ('queue-operation', 'attachment', 'last-prompt', 'ai-title'):
            dropped += 1
            continue

        # Strip the parallel toolUseResult field (the big one)
        if 'toolUseResult' in rec:
            tur = rec['toolUseResult']
            tur_str = json.dumps(tur, separators=(',', ':')) if not isinstance(tur, str) else tur
            if len(tur_str) > MAX_TR:
                rec['toolUseResult'] = tur_str[:MAX_TR] + f'...[truncated {len(tur_str) - MAX_TR} chars]'
                trimmed += 1

        # Drop the duplicated normalizedMessages field (per brtkwr.com)
        if 'normalizedMessages' in rec:
            del rec['normalizedMessages']
            trimmed += 1

        # Subagent / progress payloads
        if rtype == 'progress' and isinstance(rec.get('data'), dict):
            data = rec['data']
            if 'normalizedMessages' in data:
                del data['normalizedMessages']
                trimmed += 1
            if data.get('type') == 'bash_progress':
                out = data.get('output')
                if isinstance(out, str) and len(out) > MAX_TR:
                    data['output'] = out[:MAX_TR] + f'\n...[truncated {len(out) - MAX_TR} chars]'
                    trimmed += 1
            if data.get('type') == 'agent_progress':
                msg = data.get('message')
                if msg is not None:
                    msg_str = json.dumps(msg, separators=(',', ':')) if not isinstance(msg, str) else msg
                    if len(msg_str) > MAX_TR:
                        data['message'] = f'[truncated agent_progress.message - was {len(msg_str)} bytes]'
                        trimmed += 1

        # User records: strip images + truncate tool_results in message.content
        if rtype == 'user':
            msg = rec.get('message', {})
            content = msg.get('content')
            if isinstance(content, list):
                new_content = []
                for block in content:
                    if isinstance(block, dict):
                        # Top-level image in user message
                        if block.get('type') == 'image' and DROP_IMAGES:
                            new_content.append({'type': 'text', 'text': '[image stripped for size]'})
                            trimmed += 1
                            continue
                        # tool_result with string content
                        if block.get('type') == 'tool_result':
                            inner = block.get('content', '')
                            if isinstance(inner, str) and len(inner) > MAX_TR:
                                block = copy.deepcopy(block)
                                block['content'] = inner[:MAX_TR] + f'\n...[truncated {len(inner) - MAX_TR} chars]'
                                trimmed += 1
                            elif isinstance(inner, list):
                                # tool_result content is itself an array of blocks
                                # (e.g., screenshots from chrome-devtools or iWDP)
                                new_inner = []
                                for ib in inner:
                                    if isinstance(ib, dict):
                                        if ib.get('type') == 'image' and DROP_IMAGES:
                                            new_inner.append({'type': 'text', 'text': '[image stripped for size]'})
                                            trimmed += 1
                                            continue
                                        if ib.get('type') == 'text':
                                            t = ib.get('text', '')
                                            if len(t) > MAX_TR:
                                                ib = copy.deepcopy(ib)
                                                ib['text'] = t[:MAX_TR] + f'\n...[truncated {len(t) - MAX_TR} chars]'
                                                trimmed += 1
                                    new_inner.append(ib)
                                block = copy.deepcopy(block)
                                block['content'] = new_inner
                    new_content.append(block)
                msg['content'] = new_content

        # Assistant records: cap tool_use input bodies + thinking blocks
        if rtype == 'assistant':
            msg = rec.get('message', {})
            content = msg.get('content', [])
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict):
                        if block.get('type') == 'tool_use':
                            inp = block.get('input', {})
                            if isinstance(inp, dict):
                                for k, v in list(inp.items()):
                                    if isinstance(v, str) and len(v) > MAX_TI:
                                        inp[k] = v[:MAX_TI] + f'\n...[truncated {len(v) - MAX_TI} chars]'
                                        trimmed += 1
                        if block.get('type') == 'thinking':
                            t = block.get('thinking', '')
                            if isinstance(t, str) and len(t) > MAX_TR:
                                block['thinking'] = t[:MAX_TR] + f'\n...[truncated {len(t) - MAX_TR} chars]'
                                trimmed += 1

        out = json.dumps(rec, separators=(',', ':'), ensure_ascii=False)
        g.write(out + '\n')
        out_bytes += len(out) + 1
        kept += 1

print(f"Kept: {kept}, Trimmed: {trimmed}, Dropped: {dropped}")
print(f"Output size: {out_bytes / 1024 / 1024:.2f} MB")
