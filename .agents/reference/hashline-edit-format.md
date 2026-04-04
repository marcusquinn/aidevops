<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hashline Edit Format

Content-addressed line reference system (`LINE#HASH`) for coding agents. Prevents silent file corruption by failing loudly on stale reads with actionable recovery.

**Source**: `oh-my-pi/packages/coding-agent/src/patch/hashline.ts`

## 1. Line Reference Format

```text
LINENUM#HASH:CONTENT   ← display (shown to model)
"LINENUM#HASH"         ← reference (used in edits)
```

**Example**: `1#ZP:function hi() {` (display) / `"5#aa"` (reference — line 5, hash `aa`).

## 2. Edit Operations

| Operation | Description |
|-----------|-------------|
| `set` | Replace single line (`tag`) with `content[]` |
| `replace` | Replace range `first`→`last` (inclusive) with `content[]` |
| `append` | Insert `content[]` after `after` (EOF if omitted) |
| `prepend` | Insert `content[]` before `before` (BOF if omitted) |
| `insert` | Insert `content[]` between `after` and `before` (both required) |

`ReplaceTextEdit` (`op: "replaceText"`) is a content-addressed replacement without line numbers; not processed by `applyHashlineEdits`.

```typescript
export type LineTag = { line: number; hash: string };

export type HashlineEdit =
  | { op: "set";     tag: LineTag;                    content: string[] }
  | { op: "replace"; first: LineTag; last: LineTag;   content: string[] }
  | { op: "append";  after?: LineTag;                 content: string[] }
  | { op: "prepend"; before?: LineTag;                content: string[] }
  | { op: "insert";  after: LineTag; before: LineTag; content: string[] };
```

## 3. Staleness Detection & Recovery

Pre-validates all refs before mutation. Mismatches throw `HashlineMismatchError` with current file state. No partial mutations.

**Recovery**: Use `error.remaps` (`Map<OLD_HASH, NEW_HASH>`) to update stale refs, re-read, and retry.

**Mismatch Output Example**:
```text
2 lines changed. Use updated references (>>> marks changes).

    3#ZP:function hi() {
>>> 4#QV:  return value;
    5#HB:}
    ...
>>> 13#KT:// updated comment
```

## 4. Edit Application (`applyHashlineEdits`)

Returns `{ content, firstChangedLine, warnings?, noopEdits? }`.

**Pipeline**:
1. Snapshot `fileLines[]`.
2. Pre-validate all hashes.
3. Deduplicate `op+line+content` (Key: `s:{line}:{content}`, `r:{first}:{last}:{content}`, etc.).
4. Sort **bottom-up** (highest line first) to prevent index shifting.
5. Apply with autocorrect heuristics.

**Noop Detection**: Edits resulting in unchanged content are recorded in `noopEdits` and skipped.

**Sort Order**:
- Primary: `sortLine` descending.
- Secondary: Precedence (`set`/`replace`: 0, `append`: 1, `prepend`: 2, `insert`: 3).

## 5. Autocorrect Heuristics (`PI_HL_AUTOCORRECT=1`)

1. **Anchor Echo Stripping**: Removes echoed boundary lines from `content[]` if the model accidentally included them.
2. **Line Merge Detection**: Detects when a model merges adjacent lines (e.g., absorbing a continuation token like `&&` or `,`).
3. **Wrapped Line Restoration**: Detects and fixes accidental line reflowing (single logical line split into multiple).
4. **Indent Restoration**: Restores missing leading whitespace if `newLines.length === oldLines.length`.

## 6. Hash Algorithm (Technical Details)

- **Algorithm**: xxHash32 (`Bun.hash.xxHash32`).
- **Normalization**: Strips all whitespace (`/\s+/g`) and `\r`. Line number is NOT hashed.
- **Encoding**: 2 chars from alphabet `ZPMQVRWSNKTXJBYH`.
- **Collision**: ~0.4% per line (256 values). Line number is the primary address; hash is a staleness signal.
- **Regex**: `/^\s*[>+-]*\s*(\d+)\s*#\s*([ZPMQVRWSNKTXJBYH]{2})/`.

## 7. Streaming & Utilities

- `streamHashLinesFromUtf8`: Incremental UTF-8 decoding for large files.
- `streamHashLinesFromLines`: For pre-split line arrays.
- **Options**: `startLine` (1), `maxChunkLines` (200), `maxChunkBytes` (64KB).

## Related Files

| File | Purpose |
|------|---------|
| `patch/hashline.ts` | Core implementation |
| `patch/types.ts` | Shared types and error classes |
| `patch/index.ts` | Zod schemas for edits |
| `patch/applicator.ts` | High-level patch orchestration |
| `patch/parser.ts` | Model output parsing |
