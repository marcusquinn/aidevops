# Hashline Edit Format

Reference for the hashline edit format used in oh-my-pi's coding agent. This documents the content-addressed line reference system, edit operations, staleness detection, and autocorrect heuristics. Intended as a design guide when building custom edit tooling for headless dispatch or the objective runner.

**Source**: `oh-my-pi/packages/coding-agent/src/patch/hashline.ts`

---

## Overview

Hashline is a line-addressable edit format where each line is identified by its 1-indexed position and a short content hash. The combined `LINE#HASH` reference acts as both an address and a staleness check: if the file has changed since the caller last read it, hash mismatches are caught before any mutation occurs.

This solves a core problem with AI-generated edits: the model may reference line numbers from a stale read. Hashline makes stale references fail loudly with actionable error output rather than silently corrupting the file.

---

## Line Reference Format

### Display format (shown to the model)

```
LINENUM#HASH:CONTENT
```

Example:

```
1#ZP:function hi() {
2#HB:  return;
3#QV:}
```

### Reference format (used in edit operations)

```
"LINENUM#HASH"
```

Example: `"5#aa"` — line 5 with hash `aa`.

---

## Hash Algorithm

### Function: `computeLineHash(idx, line)`

- **Algorithm**: xxHash32 (via `Bun.hash.xxHash32`)
- **Input normalization**: strip all whitespace (`/\s+/g` → `""`) and trailing `\r`
- **Output**: 2 characters from a custom alphabet (not hex)
- **Line number**: accepted for API compatibility but not mixed into the hash

### Custom alphabet (NIBBLE_STR)

```
ZPMQVRWSNKTXJBYH
```

Each byte of the xxHash32 result is encoded as two characters from this 16-character alphabet. The low byte of the hash (`& 0xff`) selects one entry from a 256-entry lookup table (`DICT`), where each entry is a 2-char string formed from the high nibble and low nibble of the byte index.

**Why a custom alphabet?** The characters `Z P M Q V R W S N K T X J B Y H` are visually distinct and unlikely to appear in common code tokens, reducing false-positive matches when parsing references from model output.

### Parsing: `parseTag(ref)`

Accepts flexible input — the regex strips leading `>+` markers, surrounding whitespace, and optional trailing display suffixes:

```
/^\s*[>+-]*\s*(\d+)\s*#\s*([ZPMQVRWSNKTXJBYH]{2})/
```

This tolerates model output that includes diff markers or extra whitespace around the `#` separator.

---

## Edit Operations

All operations are defined in the `HashlineEdit` union type:

| Operation | Description |
|-----------|-------------|
| `set` | Replace a single line (identified by `tag`) with `content[]` |
| `replace` | Replace a range from `first` to `last` (inclusive) with `content[]` |
| `append` | Insert `content[]` after `after` (or at EOF if `after` is omitted) |
| `prepend` | Insert `content[]` before `before` (or at BOF if `before` is omitted) |
| `insert` | Insert `content[]` between `after` and `before` (both required) |

There is also a `ReplaceTextEdit` (`op: "replaceText"`) for content-addressed text replacement without line numbers, but this is a separate type not processed by `applyHashlineEdits`.

### TypeScript types

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

### Pre-validation (before any mutation)

`applyHashlineEdits` validates all line references before applying any edit. This is a two-phase approach:

1. **Collect mismatches**: iterate all edits, compute `actualHash = computeLineHash(line, fileLines[line-1])`, compare to `ref.hash`
2. **Throw once**: if any mismatches exist, throw `HashlineMismatchError` with all mismatches and the current file lines

No partial mutations occur — either all references are valid or none are applied.

### HashlineMismatchError

Thrown when one or more references are stale. The error message is grep-style output:

```
2 lines have changed since last read. Use the updated LINE#ID references shown below (>>> marks changed lines).

    3#ZP:function hi() {
>>> 4#QV:  return value;
    5#HB:}
    ...
    12#NW:export default hi;
>>> 13#KT:// updated comment
    14#BZ:
```

- `>>>` marks mismatched lines with their **current** `LINE#HASH`
- Context lines (2 above/below each mismatch) are shown with 4-space indent
- `...` separates non-contiguous regions
- `remaps` property: `Map<"LINE#OLD_HASH", "LINE#NEW_HASH">` for programmatic correction

---

## Edit Application: `applyHashlineEdits`

### Signature

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

### Processing pipeline

1. **Split** content into `fileLines[]` (mutable) and `originalFileLines[]` (immutable snapshot)
2. **Collect touched lines** — build `explicitlyTouchedLines: Set<number>` from all edit refs (used by merge detection to avoid double-counting)
3. **Pre-validate** all refs — collect mismatches, throw `HashlineMismatchError` if any
4. **Deduplicate** — remove identical edits targeting the same line(s) (same `op + line key + content`)
5. **Sort bottom-up** — sort by effective line descending so earlier splices don't shift later line numbers
6. **Apply** each edit with autocorrect heuristics (if `PI_HL_AUTOCORRECT=1`)
7. **Return** joined content, `firstChangedLine`, and any `noopEdits`

### Sort order (bottom-up)

Primary sort: `sortLine` descending (highest line first).

`sortLine` per operation:
- `set`: `tag.line`
- `replace`: `last.line`
- `append`: `after.line` (or `fileLines.length + 1` for EOF)
- `prepend`: `before.line` (or `0` for BOF)
- `insert`: `before.line`

Secondary sort: `precedence` ascending (lower = applied first when same line):
- `set`, `replace`: 0
- `append`: 1
- `prepend`: 2
- `insert`: 3

Tertiary: original index ascending (stable within same line + precedence).

### Noop detection

After autocorrect, if the resulting `newLines` equals `origLines` element-by-element, the edit is recorded as a noop (not applied, added to `noopEdits`). This prevents spurious file writes when the model re-emits unchanged content.

---

## Autocorrect Heuristics

Enabled when `PI_HL_AUTOCORRECT=1` (environment variable). These heuristics correct common model output errors before applying edits.

### 1. Anchor echo stripping

**Problem**: Models often include the anchor line in their replacement content, even though the anchor is not being replaced.

**Three variants**:

#### `stripInsertAnchorEchoAfter(anchorLine, dstLines)`
Used for `append` operations. If `dstLines[0]` equals `anchorLine` (ignoring whitespace), strip it.

```
append after line 5 ("function foo() {"):
  content: ["function foo() {", "  return 1;", "}"]
  →  strips first line → ["  return 1;", "}"]
```

#### `stripInsertAnchorEchoBefore(anchorLine, dstLines)`
Used for `prepend` operations. If `dstLines[last]` equals `anchorLine` (ignoring whitespace), strip it.

#### `stripInsertBoundaryEcho(afterLine, beforeLine, dstLines)`
Used for `insert` operations. Strips both boundaries if echoed:
- If `dstLines[0]` equals `afterLine`, strip first
- If `dstLines[last]` equals `beforeLine`, strip last

#### `stripRangeBoundaryEcho(fileLines, startLine, endLine, dstLines)`
Used for `set` and `replace`. Strips the line immediately before `startLine` and immediately after `endLine` if echoed in `dstLines`. Only activates when `dstLines.length > 1` and `dstLines.length > count` (the model grew the edit), to avoid turning a single-line replacement into a deletion.

### 2. Line merge detection: `maybeExpandSingleLineMerge`

**Problem**: Models sometimes merge two adjacent lines into one when editing a single line. For example, a continuation line like:

```
14: const result = foo
15:   .bar()
```

The model edits line 14 but produces `"const result = foo.bar()"` — absorbing line 15.

**Detection**: Only triggered for `set` operations with `content.length === 1`.

**Case A — absorbed next line** (current line looks like a continuation):
- `origLooksLikeContinuation`: `stripTrailingContinuationTokens(origCanon).length < origCanon.length`
- Trailing continuation tokens: `&&`, `||`, `??`, `?`, `:`, `=`, `,`, `+`, `-`, `*`, `/`, `.`, `(`
- Check: `newCanon` contains both `origCanonForMatch` and `nextCanon` in order, and `newCanon.length <= origCanon.length + nextCanon.length + 32`
- Result: `{ startLine: line, deleteCount: 2, newLines: [newLine] }` — replaces 2 lines with 1

**Case B — absorbed previous line** (previous line looks like a continuation):
- Check: previous line ends with a continuation token
- Uses `stripMergeOperatorChars` (removes `|`, `&`, `?`) to handle operator changes like `||` → `??`
- Check: `newCanonForMergeOps` contains both `prevCanonForMatch` and `origCanonForMergeOps` in order
- Result: `{ startLine: line - 1, deleteCount: 2, newLines: [newLine] }` — replaces 2 lines with 1

**Guard**: `explicitlyTouchedLines` prevents merge detection from consuming a line that another edit is explicitly targeting.

### 3. Wrapped line restoration: `restoreOldWrappedLines`

**Problem**: Models sometimes reflow a single logical line into multiple lines (or vice versa) when the token content is identical.

**Algorithm**:
1. Build `canonToOld: Map<strippedContent, { line, count }>` from `oldLines`
2. For each span of 2–10 consecutive `newLines`, compute `canonSpan = stripAllWhitespace(joined)`
3. If `canonSpan` matches a unique old line (count=1) and `canonSpan.length >= 6`, record as a candidate
4. Filter to candidates whose `canonSpan` is unique in the new output (no ambiguity)
5. Apply back-to-front (highest start index first) to keep indices stable: `splice(start, len, replacement)`

This restores the original single line, undoing the model's reformatting.

### 4. Indent restoration: `restoreIndentForPairedReplacement`

**Problem**: Models sometimes strip leading indentation from replacement lines.

**Condition**: Only applied when `oldLines.length === newLines.length` (paired replacement).

**Algorithm**: For each line pair `(oldLines[i], newLines[i])`:
- If `newLines[i]` has no leading whitespace but `oldLines[i]` does, prepend `oldLines[i]`'s leading whitespace to `newLines[i]`
- If `newLines[i]` already has leading whitespace, leave it unchanged

Returns the original `newLines` array if no changes were made (avoids allocation).

---

## Streaming Formatters

For large files, two async generator functions stream hashline-formatted output in chunks rather than allocating a single large string.

### `streamHashLinesFromUtf8(source, options)`

Accepts a `ReadableStream<Uint8Array>` or `AsyncIterable<Uint8Array>`. Decodes UTF-8 incrementally, handles partial chunks, and emits `\n`-joined formatted line strings.

### `streamHashLinesFromLines(lines, options)`

Accepts `Iterable<string>` or `AsyncIterable<string>`. Simpler path when lines are already split.

### Chunk options (`HashlineStreamOptions`)

| Option | Default | Description |
|--------|---------|-------------|
| `startLine` | 1 | First line number |
| `maxChunkLines` | 200 | Max formatted lines per yielded chunk |
| `maxChunkBytes` | 65536 (64 KiB) | Max UTF-8 bytes per yielded chunk |

Chunks are flushed when either limit is reached. The final chunk is always flushed at stream end.

---

## Implementation Notes for Custom Tooling

### Enabling autocorrect

Set `PI_HL_AUTOCORRECT=1` in the environment before calling `applyHashlineEdits`. Without it, all heuristics are bypassed and content is applied verbatim.

### Error recovery flow

```
1. Call applyHashlineEdits(content, edits)
2. If HashlineMismatchError thrown:
   a. Use error.remaps to update stale refs: Map<"LINE#OLD", "LINE#NEW">
   b. Re-read the file (content may have changed)
   c. Recompute edits with updated refs
   d. Retry
3. Check result.noopEdits — these edits had no effect (model re-emitted unchanged content)
4. Check result.warnings for non-fatal issues
```

### Hash collision probability

The hash is 2 characters from a 16-char alphabet = 256 possible values. Collision probability per line is ~0.4% (1/256). For a 1000-line file with 10 edits, expected false-pass rate is low but non-zero. The line number component provides the primary address; the hash is a staleness signal, not a cryptographic guarantee.

### Bottom-up application is mandatory

Edits must be applied bottom-up (highest line first). Applying top-down would shift line numbers for all subsequent edits. The sort in `applyHashlineEdits` handles this automatically, but custom implementations must replicate this ordering.

### Deduplication key format

```
"s:{line}:{content}"         // set
"r:{first}:{last}:{content}" // replace
"i:{after}:{content}"        // append
"ib:{before}:{content}"      // prepend
"ix:{after}:{before}:{content}" // insert
```

Content is the `\n`-joined `content[]` array.

---

## Related Files

| File | Purpose |
|------|---------|
| `patch/hashline.ts` | Core implementation (this document's source) |
| `patch/types.ts` | `HashMismatch`, `LineTag`, shared error classes |
| `patch/index.ts` | Schema definitions (`hashlineEditItemSchema`, `hashlineEditSchema`) |
| `patch/applicator.ts` | Higher-level patch application (uses hashline internally) |
| `patch/parser.ts` | Parses model output into `EditSpec[]` |
