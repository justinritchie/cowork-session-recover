#!/usr/bin/env python3
"""Repair a Claude Code / Cowork session JSONL whose parentUuid chain is broken.

Symptoms this addresses (orthogonal to the size-bloat that trim_jsonl.py fixes):
- Session resumes with only 4-17% of the conversation visible
- "Conversation history missing on resume" — UI shows only the last few turns
- Walking parentUuid backwards stops at a missing UUID
- file-history-snapshot entries collide with real message UUIDs

Three bug classes documented across Claude Code GitHub issues #24304, #35024,
#37437, #46603:

1. **Orphan parentUuid references** — entries reference a parent UUID that
   doesn't exist anywhere in the file. Most often from `progress` entries that
   reference an in-flight tool result UUID that was never flushed to disk
   (queued user message interrupts a streaming tool call), or from 403 retries
   that re-emit the user message with a sidechain parentUuid.

2. **Snapshot messageId collisions** — `file-history-snapshot` entries have a
   `messageId` field that collides with a real message's `uuid`, creating
   ambiguity in the chain walker.

3. **Disconnected compaction roots** — `/compact` creates new entries with
   `parentUuid: null` that split the conversation into unreachable subtrees.

This script is a port of the patterns in:
- pchalasani.github.io/claude-code-tools (fix-session CLI)
- gist.github.com/tennox/90ef5c803ec4b64c9fbba0f71ca1ae2e (snapshot collision)
- cacheoverflow.dev/blog/u-0oY5DW (orphan repair)

Usage:
    repair_chain.py <input.jsonl> [--analyze | --fix-in-place | --output FILE]
"""
import argparse, json, sys, copy
from collections import defaultdict


def load_entries(path):
    """Load JSONL into list of (line_no, dict) tuples; preserve unparseable lines."""
    entries = []
    with open(path) as f:
        for n, line in enumerate(f, start=1):
            line = line.rstrip('\n')
            if not line:
                continue
            try:
                entries.append((n, json.loads(line)))
            except Exception:
                entries.append((n, None))
    return entries


def collect_uuids(entries):
    """All real UUIDs that exist as the `uuid` field of an entry."""
    return {e['uuid'] for _, e in entries if e and 'uuid' in e}


def find_orphans(entries, uuids):
    """Entries whose parentUuid points to a UUID not present in the file."""
    orphans = []
    for n, e in entries:
        if not e:
            continue
        p = e.get('parentUuid')
        if p and p not in uuids:
            orphans.append((n, e))
    return orphans


def find_snapshot_collisions(entries, uuids):
    """file-history-snapshot entries whose messageId collides with a real uuid."""
    collisions = []
    for n, e in entries:
        if not e or e.get('type') != 'file-history-snapshot':
            continue
        mid = e.get('messageId')
        if mid and mid in uuids:
            collisions.append((n, e))
    return collisions


def find_disconnected_roots(entries):
    """Entries with parentUuid=null that aren't the very first conversation entry."""
    roots = []
    seen_first = False
    for n, e in entries:
        if not e or 'uuid' not in e:
            continue
        if e.get('parentUuid') is None:
            if seen_first:
                roots.append((n, e))
            seen_first = True
    return roots


def find_nearest_valid_predecessor(entries, target_index, uuids):
    """Walk backwards from target_index to find the nearest entry with a real uuid."""
    for n, e in reversed(entries[:target_index]):
        if e and 'uuid' in e and e['uuid'] in uuids:
            return e['uuid']
    return None


def repair_orphans(entries, uuids):
    """Repoint orphan parentUuids to the nearest valid predecessor."""
    fixed = 0
    for i, (n, e) in enumerate(entries):
        if not e:
            continue
        p = e.get('parentUuid')
        if p and p not in uuids:
            new_parent = find_nearest_valid_predecessor(entries, i, uuids)
            if new_parent:
                e['parentUuid'] = new_parent
                fixed += 1
    return fixed


def repair_snapshot_collisions(entries, uuids):
    """Set messageId to null on file-history-snapshot entries that collide."""
    fixed = 0
    for n, e in entries:
        if not e or e.get('type') != 'file-history-snapshot':
            continue
        mid = e.get('messageId')
        if mid and mid in uuids:
            e['messageId'] = None
            fixed += 1
    return fixed


def repair_disconnected_roots(entries):
    """Connect parentUuid=null entries (after the first one) to the preceding entry."""
    fixed = 0
    seen_first = False
    last_real_uuid = None
    for n, e in entries:
        if not e or 'uuid' not in e:
            continue
        if e.get('parentUuid') is None:
            if seen_first and last_real_uuid:
                e['parentUuid'] = last_real_uuid
                fixed += 1
            seen_first = True
        last_real_uuid = e.get('uuid', last_real_uuid)
    return fixed


def write_entries(entries, path):
    with open(path, 'w') as f:
        for _, e in entries:
            if e is None:
                f.write('\n')  # preserve unparseable line as blank
            else:
                f.write(json.dumps(e, separators=(',', ':'), ensure_ascii=False) + '\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('infile')
    ap.add_argument('--analyze', action='store_true', help='Report only, no changes')
    ap.add_argument('--fix-in-place', action='store_true', help='Repair file in place (creates .bak)')
    ap.add_argument('--output', help='Write repaired version to this path')
    args = ap.parse_args()

    entries = load_entries(args.infile)
    uuids = collect_uuids(entries)
    orphans = find_orphans(entries, uuids)
    collisions = find_snapshot_collisions(entries, uuids)
    roots = find_disconnected_roots(entries)

    total = len([e for _, e in entries if e])
    print(f"Total entries:                {total}")
    print(f"Distinct UUIDs:               {len(uuids)}")
    print(f"Orphan parentUuid references: {len(orphans)}")
    print(f"Snapshot messageId collisions:{len(collisions)}")
    print(f"Disconnected compaction roots:{len(roots)}")
    if orphans:
        print(f"\nFirst 5 orphan examples:")
        for n, e in orphans[:5]:
            print(f"  L{n}: type={e.get('type')} parentUuid={e.get('parentUuid','')[:12]}...")

    if args.analyze:
        return

    if not (args.fix_in_place or args.output):
        print("\nRun with --analyze, --fix-in-place, or --output FILE to act.")
        return

    f1 = repair_orphans(entries, uuids)
    f2 = repair_snapshot_collisions(entries, uuids)
    f3 = repair_disconnected_roots(entries)
    print(f"\nRepaired: orphans={f1}, snapshot_collisions={f2}, disconnected_roots={f3}")

    if args.fix_in_place:
        from datetime import datetime, timezone
        bak = f"{args.infile}.bak-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
        import shutil
        shutil.copy2(args.infile, bak)
        write_entries(entries, args.infile)
        print(f"Backup: {bak}")
        print(f"Repaired in place: {args.infile}")
    elif args.output:
        write_entries(entries, args.output)
        print(f"Wrote: {args.output}")


if __name__ == '__main__':
    main()
