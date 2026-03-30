# Hashline Edit Format

Content-addressed line reference system (`LINE#HASH`) for oh-my-pi's coding agent. Hash mismatches on stale reads fail loudly with actionable output instead of silently corrupting files.

**Source**: `oh-my-pi/packages/coding-agent/src/patch/hashline.ts`

## Line Reference Format

```text
LINENUM#HASH:CONTENT   ← display (shown to model)
"LINENUM#HASH"         ← reference (used in edits)
```

Example: `1#ZP:function hi() {` (display) / `"5#aa"` (reference — line 5, hash `aa`).

## Hash Algorithm

**`computeLineHash(idx, line)`** — xxHash32 (`Bun.hash.xxHash32`). Strips whitespace (`/\s+/g` → `""`) and trailing `\r`; line number accepted but not mixed into hash. Output: 2 chars from alphabet `ZPMQVRWSNKTXJBYH` (visually distinct, unlikely in code). Encoding: low byte (`& 0xff`) → 256-entry lookup table mapping high/low nibbles to alphabet.

**`parseTag(ref)`** — regex: `/^\s*[>+-]*\s*(\d+)\s*#\s*([ZPMQVRWSNKTXJBYH]{2})/`. Strips leading `>+` markers, whitespace, trailing display suffixes. Tolerates diff markers.

**Collision**: 2 chars × 16-char alphabet = 256 values (~0.4% per line). Line number is primary address; hash is staleness signal, not cryptographic guarantee.

## Edit Operations

| Operation | Description |
|-----------|-------------|
| `set` | Replace single line (`tag`) with `content[]` |
| `replace` | Replace range `first`→`last` (inclusive) with `content[]` |
| `append` | Insert `content[]` after `after` (EOF if omitted) |
| `prepend` | Insert `content[]` before `before` (BOF if omitted) |
| `insert` | Insert `content[]` between `after` and `before` (both required) |

`ReplaceTextEdit` (`op: "replaceText"`) — content-addressed replacement without line numbers; not processed by `applyHashlineEdits`.

```typescript
export type LineTag = { line: number; hash: string };

export type HashlineEdit =
  | { op: "set";     tag: LineTag;                    content: string[] }
  | { op: "replace"; first: LineTag; last: LineTag;   content: string[] }
  | { op: "append";  after?: LineTag;                 content: string[] }
  | { op: "prepend"; before?: LineTag;                content: string[] }
  | { op: "insert";  after: LineTag; before: LineTag; content: string[] };
```

## Staleness Detection

Pre-validates all refs before mutation. For each ref, computes `actualHash = computeLineHash(line, fileLines[line-1])`; any mismatch throws `HashlineMismatchError` with all mismatches and current file lines. No partial mutations.

**HashlineMismatchError** output:

```text
2 lines have changed since last read. Use the updated LINE#HASH references shown below (>>> marks changed lines).

    3#ZP:function hi() {
>>> 4#QV:  return value;
    5#HB:}
    ...
>>> 13#KT:// updated comment
```

`>>>` marks mismatched lines with **current** `LINE#HASH` (2 lines context; `...` separates regions). `remaps`: `Map<"LINE#OLD_HASH", "LINE#NEW_HASH">` for programmatic correction.

**Recovery**: use `error.remaps` to update stale refs, re-read file, recompute edits, retry. Check `result.noopEdits` and `result.warnings`.

## Edit Application: `applyHashlineEdits`

Returns `{ content, firstChangedLine, warnings?, noopEdits? }`. Pipeline: (1) split `fileLines[]` + `originalFileLines[]` snapshot; (2) build `explicitlyTouchedLines: Set<number>`; (3) pre-validate refs; (4) deduplicate `op+line+content`; (5) sort bottom-up; (6) apply with autocorrect; (7) return result.

**Sort order** — primary: `sortLine` descending (`set`→`tag.line`, `replace`→`last.line`, `append`→`after.line`/EOF, `prepend`→`before.line`/0, `insert`→`before.line`). Secondary: precedence ascending (`set`/`replace`: 0, `append`: 1, `prepend`: 2, `insert`: 3). Tertiary: original index (stable).

**Bottom-up mandatory**: highest-line-first avoids shifting line numbers for subsequent edits. `applyHashlineEdits` handles this; custom implementations must replicate.

**Noop detection** — `newLines` equals `origLines` element-by-element after autocorrect → recorded in `noopEdits`, not applied. Prevents spurious writes on unchanged content.

**Dedup key format** (`\n`-joined `content[]`):

```text
"s:{line}:{content}"             // set
"r:{first}:{last}:{content}"     // replace
"i:{after}:{content}"            // append
"ib:{before}:{content}"          // prepend
"ix:{after}:{before}:{content}"  // insert
```

## Autocorrect Heuristics

Enabled when `PI_HL_AUTOCORRECT=1`. All heuristics bypassed without it.

### 1. Anchor echo stripping

Models often echo the anchor line in replacement content despite it not being replaced.

| Function | Op | Strips |
|----------|----|--------|
| `stripInsertAnchorEchoAfter(anchorLine, dstLines)` | `append` | `dstLines[0]` if equals `anchorLine` (ignoring whitespace) |
| `stripInsertAnchorEchoBefore(anchorLine, dstLines)` | `prepend` | `dstLines[last]` if equals `anchorLine` |
| `stripInsertBoundaryEcho(afterLine, beforeLine, dstLines)` | `insert` | Both boundaries if echoed |
| `stripRangeBoundaryEcho(fileLines, startLine, endLine, dstLines)` | `set`/`replace` | Lines before `startLine` / after `endLine` if echoed as first/last of `dstLines`. Only when `dstLines.length > 1` and `> count`. |

### 2. Line merge detection: `maybeExpandSingleLineMerge`

Triggered only for `set` with `content.length === 1`. Detects model merging two adjacent lines into one.

- **Case A — absorbed next**: `origLooksLikeContinuation` when `stripTrailingContinuationTokens` shortens canonical form. Tokens: `&&`, `||`, `??`, `?`, `:`, `=`, `,`, `+`, `-`, `*`, `/`, `.`, `(`. → `{ startLine: line, deleteCount: 2 }`.
- **Case B — absorbed previous**: previous line ends with continuation token; `stripMergeOperatorChars` (removes `|`, `&`, `?`) for operator changes like `||` → `??`. → `{ startLine: line-1, deleteCount: 2 }`.
- **Guard**: `explicitlyTouchedLines` prevents consuming a line targeted by another edit.

### 3. Wrapped line restoration: `restoreOldWrappedLines`

Detects model reflowing a single logical line into multiple. Builds `canonToOld: Map<strippedContent, { line, count }>` from `oldLines`; for spans of 2-10 consecutive `newLines`, if `canonSpan` matches a unique old line (`count=1`, `length >= 6`) and is unique in new output, restores back-to-front via `splice`.

### 4. Indent restoration: `restoreIndentForPairedReplacement`

Only when `oldLines.length === newLines.length`. For each pair: if `newLines[i]` has no leading whitespace but `oldLines[i]` does, prepend `oldLines[i]`'s indent.

## Streaming Formatters

| Function | Input | Notes |
|----------|-------|-------|
| `streamHashLinesFromUtf8(source, options)` | `ReadableStream<Uint8Array>` or `AsyncIterable<Uint8Array>` | Decodes UTF-8 incrementally, handles partial chunks |
| `streamHashLinesFromLines(lines, options)` | `Iterable<string>` or `AsyncIterable<string>` | Simpler path when lines are pre-split |

**`HashlineStreamOptions`**: `startLine` (1), `maxChunkLines` (200), `maxChunkBytes` (65536). Flushes on either limit; final chunk flushes at stream end.

## Related Files

| File | Purpose |
|------|---------|
| `patch/hashline.ts` | Core implementation (this document's source) |
| `patch/types.ts` | `HashMismatch`, `LineTag`, shared error classes |
| `patch/index.ts` | Schema definitions (`hashlineEditItemSchema`, `hashlineEditSchema`) |
| `patch/applicator.ts` | Higher-level patch application (uses hashline internally) |
| `patch/parser.ts` | Parses model output into `EditSpec[]` |
