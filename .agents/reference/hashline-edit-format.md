# Hashline Edit Format

Content-addressed line reference system used in oh-my-pi's coding agent. Each line is identified by `LINE#HASH` — a combined address and staleness check. Hash mismatches on stale reads fail loudly with actionable output rather than silently corrupting the file.

**Source**: `oh-my-pi/packages/coding-agent/src/patch/hashline.ts`

---

## Line Reference Format

```
LINENUM#HASH:CONTENT   ← display format (shown to model)
"LINENUM#HASH"         ← reference format (used in edit operations)
```

Example: `1#ZP:function hi() {` / `"5#aa"` — line 5, hash `aa`.

---

## Hash Algorithm

### `computeLineHash(idx, line)`

- **Algorithm**: xxHash32 (`Bun.hash.xxHash32`)
- **Input**: strip all whitespace (`/\s+/g` → `""`) and trailing `\r`; line number accepted but not mixed into hash
- **Output**: 2 chars from alphabet `ZPMQVRWSNKTXJBYH` (visually distinct, unlikely in code tokens)
- **Encoding**: low byte of xxHash32 (`& 0xff`) indexes a 256-entry lookup table; each entry maps high/low nibbles to the alphabet

### `parseTag(ref)`

```
/^\s*[>+-]*\s*(\d+)\s*#\s*([ZPMQVRWSNKTXJBYH]{2})/
```

Strips leading `>+` markers, surrounding whitespace, and optional trailing display suffixes. Tolerates diff markers in model output.

---

## Edit Operations

| Operation | Description |
|-----------|-------------|
| `set` | Replace single line (`tag`) with `content[]` |
| `replace` | Replace range `first`→`last` (inclusive) with `content[]` |
| `append` | Insert `content[]` after `after` (EOF if omitted) |
| `prepend` | Insert `content[]` before `before` (BOF if omitted) |
| `insert` | Insert `content[]` between `after` and `before` (both required) |

`ReplaceTextEdit` (`op: "replaceText"`) is a separate type for content-addressed replacement without line numbers; not processed by `applyHashlineEdits`.

```typescript
export type LineTag = { line: number; hash: string };

export type HashlineEdit =
  | { op: "set";     tag: LineTag;                    content: string[] }
  | { op: "replace"; first: LineTag; last: LineTag;   content: string[] }
  | { op: "append";  after?: LineTag;                 content: string[] }
  | { op: "prepend"; before?: LineTag;                content: string[] }
  | { op: "insert";  after: LineTag; before: LineTag; content: string[] };
```

---

## Staleness Detection

`applyHashlineEdits` validates all refs before any mutation. Computes `actualHash = computeLineHash(line, fileLines[line-1])` for each ref; if any mismatch, throws `HashlineMismatchError` with all mismatches and current file lines. No partial mutations.

### HashlineMismatchError

```
2 lines have changed since last read. Use the updated LINE#HASH references shown below (>>> marks changed lines).

    3#ZP:function hi() {
>>> 4#QV:  return value;
    5#HB:}
    ...
>>> 13#KT:// updated comment
```

- `>>>` marks mismatched lines with their **current** `LINE#HASH`
- Context: 2 lines above/below each mismatch; `...` separates non-contiguous regions
- `remaps`: `Map<"LINE#OLD_HASH", "LINE#NEW_HASH">` for programmatic correction

---

## Edit Application: `applyHashlineEdits`

```typescript
function applyHashlineEdits(
  content: string,
  edits: HashlineEdit[],
): {
  content: string;
  firstChangedLine: number | undefined;
  warnings?: string[];
  noopEdits?: Array<{ editIndex: number; loc: string; currentContent: string }>;
}
```

**Pipeline**: (1) split into `fileLines[]` + `originalFileLines[]` snapshot; (2) build `explicitlyTouchedLines: Set<number>`; (3) pre-validate refs; (4) deduplicate same `op+line+content`; (5) sort bottom-up; (6) apply with autocorrect; (7) return content + `firstChangedLine` + `noopEdits`.

**Sort order** — primary: `sortLine` descending (`set`→`tag.line`, `replace`→`last.line`, `append`→`after.line`/EOF, `prepend`→`before.line`/0, `insert`→`before.line`). Secondary: precedence ascending (`set`/`replace`: 0, `append`: 1, `prepend`: 2, `insert`: 3). Tertiary: original index (stable).

**Noop detection** — if `newLines` equals `origLines` element-by-element after autocorrect, edit is recorded in `noopEdits` and not applied. Prevents spurious writes when model re-emits unchanged content.

---

## Autocorrect Heuristics

Enabled when `PI_HL_AUTOCORRECT=1`. All heuristics bypassed without it.

### 1. Anchor echo stripping

Models often include the anchor line in replacement content even though it's not being replaced.

| Function | Op | Strips |
|----------|----|--------|
| `stripInsertAnchorEchoAfter(anchorLine, dstLines)` | `append` | `dstLines[0]` if equals `anchorLine` (ignoring whitespace) |
| `stripInsertAnchorEchoBefore(anchorLine, dstLines)` | `prepend` | `dstLines[last]` if equals `anchorLine` |
| `stripInsertBoundaryEcho(afterLine, beforeLine, dstLines)` | `insert` | Both boundaries if echoed |
| `stripRangeBoundaryEcho(fileLines, startLine, endLine, dstLines)` | `set`/`replace` | Lines before `startLine` / after `endLine` if echoed as first/last of `dstLines`. Only when `dstLines.length > 1` and `> count`. |

### 2. Line merge detection: `maybeExpandSingleLineMerge`

Models sometimes merge two adjacent lines into one. Only triggered for `set` with `content.length === 1`.

**Case A — absorbed next line**: `origLooksLikeContinuation` when `stripTrailingContinuationTokens(origCanon).length < origCanon.length`. Tokens: `&&`, `||`, `??`, `?`, `:`, `=`, `,`, `+`, `-`, `*`, `/`, `.`, `(`. Check: `newCanon` contains both `origCanonForMatch` and `nextCanon` in order within `origCanon.length + nextCanon.length + 32`. Result: `{ startLine: line, deleteCount: 2 }`.

**Case B — absorbed previous line**: previous line ends with continuation token. Uses `stripMergeOperatorChars` (removes `|`, `&`, `?`) for operator changes like `||` → `??`. Check: `newCanonForMergeOps` contains both `prevCanonForMatch` and `origCanonForMergeOps` in order. Result: `{ startLine: line-1, deleteCount: 2 }`.

**Guard**: `explicitlyTouchedLines` prevents merge detection from consuming a line targeted by another edit.

### 3. Wrapped line restoration: `restoreOldWrappedLines`

Models sometimes reflow a single logical line into multiple lines. Algorithm: build `canonToOld: Map<strippedContent, { line, count }>` from `oldLines`; for each span of 2–10 consecutive `newLines`, compute `canonSpan = stripAllWhitespace(joined)`; if it matches a unique old line (`count=1`, `length >= 6`) and is unique in new output, apply back-to-front: `splice(start, len, replacement)`.

### 4. Indent restoration: `restoreIndentForPairedReplacement`

Only when `oldLines.length === newLines.length`. For each pair: if `newLines[i]` has no leading whitespace but `oldLines[i]` does, prepend `oldLines[i]`'s indent. Returns original array if unchanged.

---

## Streaming Formatters

| Function | Input | Notes |
|----------|-------|-------|
| `streamHashLinesFromUtf8(source, options)` | `ReadableStream<Uint8Array>` or `AsyncIterable<Uint8Array>` | Decodes UTF-8 incrementally, handles partial chunks |
| `streamHashLinesFromLines(lines, options)` | `Iterable<string>` or `AsyncIterable<string>` | Simpler path when lines are pre-split |

**`HashlineStreamOptions`**: `startLine` (default: 1), `maxChunkLines` (default: 200), `maxChunkBytes` (default: 65536). Chunks flush when either limit is reached; final chunk always flushes at stream end.

---

## Implementation Notes

- **Autocorrect**: set `PI_HL_AUTOCORRECT=1` before calling `applyHashlineEdits`; without it all heuristics are bypassed.
- **Bottom-up is mandatory**: apply highest-line-first; top-down shifts line numbers for subsequent edits. `applyHashlineEdits` handles this; custom implementations must replicate it.
- **Hash collision**: 2 chars from 16-char alphabet = 256 values, ~0.4% collision per line. Line number is the primary address; hash is a staleness signal, not a cryptographic guarantee.

### Error recovery flow

```
1. Call applyHashlineEdits(content, edits)
2. If HashlineMismatchError:
   a. Use error.remaps: Map<"LINE#OLD", "LINE#NEW"> to update stale refs
   b. Re-read the file
   c. Recompute edits with updated refs
   d. Retry
3. Check result.noopEdits — edits with no effect
4. Check result.warnings for non-fatal issues
```

### Deduplication key format

```
"s:{line}:{content}"             // set
"r:{first}:{last}:{content}"     // replace
"i:{after}:{content}"            // append
"ib:{before}:{content}"          // prepend
"ix:{after}:{before}:{content}"  // insert
```

Content is `\n`-joined `content[]`.

---

## Related Files

| File | Purpose |
|------|---------|
| `patch/hashline.ts` | Core implementation (this document's source) |
| `patch/types.ts` | `HashMismatch`, `LineTag`, shared error classes |
| `patch/index.ts` | Schema definitions (`hashlineEditItemSchema`, `hashlineEditSchema`) |
| `patch/applicator.ts` | Higher-level patch application (uses hashline internally) |
| `patch/parser.ts` | Parses model output into `EditSpec[]` |
