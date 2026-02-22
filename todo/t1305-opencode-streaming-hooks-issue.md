# t1305: OpenCode Upstream Issue Draft

**Upstream issue created:** https://github.com/anomalyco/opencode/issues/14691

## Target Repository

`anomalyco/opencode` (108k+ stars)

## Issue Title

`[FEATURE]: Plugin hooks for streaming token observation (stream.delta) and abort handling (stream.aborted)`

## Research Summary

### Existing Related Issues (no direct overlap)

| Issue | Title | Relevance |
|-------|-------|-----------|
| #9737 | Expose partial tool arguments during streaming via state.raw | Identifies the exact `tool-input-delta: break` no-op in `processor.ts`. Focuses on UI state, not plugin hooks. |
| #13524 | Refactor: centralize tool plugin hooks + add agent to hook input | Centralizes existing hooks, doesn't add streaming hooks. |
| #12472 | Native Claude Code hooks compatibility (PreToolUse, PostToolUse, Stop) | Maps Claude Code hooks to OpenCode events. No streaming-level hooks. |
| #14451 | Ability to intercept or emulate agent messages in plugins | Message interception, not token-level streaming. |
| #10374 | Allow "aborted" agents to be continued | Abort recovery for subagents, not streaming abort. |
| #8197 | Add retry/re-run capability when operation is aborted | UI retry button, not programmatic abort handling. |
| #13809 | Preserve partial bash output for the model after abort | Partial output preservation, not plugin hooks. |

### Key Finding

The `processor.ts` streaming loop (line ~120) has explicit no-ops for `tool-input-delta` and `tool-input-end`:

```typescript
case "tool-input-delta":
  break  // Delta discarded
case "tool-input-end":
  break  // Completion ignored
```

The `text-delta` case accumulates text but has no plugin hook (only `text-end` triggers `experimental.text.complete`).

No existing issue proposes plugin hooks at the streaming token level.

### Existing Hook System

The `Hooks` interface in `packages/plugin/src/index.ts` follows a consistent pattern:
- Input: context object (sessionID, messageID, etc.)
- Output: mutable object the hook can modify
- Triggered via `Plugin.trigger(name, input, output)`

Current hooks: `chat.message`, `chat.params`, `tool.execute.before/after`, `experimental.text.complete`, etc.

## Motivation (from oh-my-pi benchmark data)

Can Boluk's "The Harness Problem" (2026-02-12) demonstrated that harness engineering is the highest-leverage optimization available:

- **15 LLMs improved** by changing only the edit tool format (hashline)
- **5-68% success rate gains** across models (Grok Code Fast 1: 6.7% -> 68.3%)
- **20-61% token reduction** (Grok 4 Fast output tokens dropped 61%)
- **Zero training compute** required

The key insight: the harness (tool layer between model output and workspace) is where most failures happen. Streaming hooks enable a new class of harness optimizations:

1. **TTSR (Time-To-Stream Rules)**: Observe tokens as they stream, detect patterns (e.g., model about to repeat a known mistake), inject corrective steering before the model commits to a bad path
2. **Early abort on waste**: Detect when the model is generating obviously wrong output (wrong language, hallucinated imports, infinite loops) and abort early to save tokens
3. **Real-time observability**: Token-level metrics, latency tracking, pattern detection

## Proposed Hooks

### 1. `stream.delta`

Observe individual streaming tokens/chunks. Optionally signal abort.

```typescript
"stream.delta"?: (
  input: {
    sessionID: string
    messageID: string
    partID: string
    type: "text" | "reasoning" | "tool-input"
    /** For tool-input deltas, the tool name and call ID */
    tool?: { name: string; callID: string }
  },
  output: {
    delta: string
    /** Set to true to abort the current stream */
    abort?: boolean
  },
) => Promise<void>
```

**Use cases:**
- TTSR: pattern-match streaming text against rules, abort when a known-bad pattern is detected
- Token counting: real-time token budget enforcement
- UI: progressive rendering of tool inputs (subsumes #9737)
- Observability: TTFT measurement, throughput tracking

### 2. `stream.aborted`

Handle stream abort (whether user-initiated, plugin-initiated, or error-induced). Optionally retry or inject a steering message.

```typescript
"stream.aborted"?: (
  input: {
    sessionID: string
    messageID: string
    reason: "user" | "plugin" | "error" | "timeout"
    /** Accumulated text so far */
    partial: string
    /** If plugin-initiated, which plugin triggered the abort */
    source?: string
  },
  output: {
    /** Set to true to retry the stream from scratch */
    retry?: boolean
    /** Inject a user message before retry (steering) */
    injectMessage?: string
  },
) => Promise<void>
```

**Use cases:**
- TTSR steering: abort detected bad pattern, inject corrective instruction, retry
- Graceful degradation: on timeout, inject "please be more concise" and retry
- Abort analytics: track why streams are aborted, which models/prompts cause issues
- Recovery: preserve partial output context for the retry attempt

## Code Sketch: Changes to processor.ts

The change is modest -- ~30 lines added to the existing streaming loop:

```typescript
// In processor.ts, within the for-await-of stream.fullStream loop:

case "text-delta":
  if (currentText) {
    // NEW: trigger stream.delta hook
    const deltaOutput = await Plugin.trigger(
      "stream.delta",
      {
        sessionID: input.sessionID,
        messageID: input.assistantMessage.id,
        partID: currentText.id,
        type: "text",
      },
      { delta: value.text },
    )
    if (deltaOutput.abort) {
      // Record abort reason and break out of stream
      abortReason = "plugin"
      break
    }

    currentText.text += deltaOutput.delta
    // ... existing updatePartDelta logic
  }
  break

case "tool-input-delta":
  // NEW: instead of `break`, accumulate and trigger hook
  const toolMatch = toolcalls[value.id]
  if (toolMatch && toolMatch.state.status === "pending") {
    const deltaOutput = await Plugin.trigger(
      "stream.delta",
      {
        sessionID: input.sessionID,
        messageID: input.assistantMessage.id,
        partID: toolMatch.id,
        type: "tool-input",
        tool: { name: toolMatch.tool, callID: value.id },
      },
      { delta: value.delta },
    )
    if (deltaOutput.abort) {
      abortReason = "plugin"
      break
    }
    // Accumulate raw (also addresses #9737)
    await Session.updatePart({
      ...toolMatch,
      state: {
        ...toolMatch.state,
        raw: (toolMatch.state.raw || "") + deltaOutput.delta,
      },
    })
  }
  break

// After the stream loop, before error handling:
if (abortReason) {
  const abortOutput = await Plugin.trigger(
    "stream.aborted",
    {
      sessionID: input.sessionID,
      messageID: input.assistantMessage.id,
      reason: abortReason,
      partial: currentText?.text ?? "",
    },
    { retry: false, injectMessage: undefined },
  )
  if (abortOutput.retry) {
    if (abortOutput.injectMessage) {
      // Inject steering message as user input before retry
      await Session.addUserMessage(input.sessionID, abortOutput.injectMessage)
    }
    continue // Re-enter the while(true) loop
  }
}
```

## Design Considerations

1. **Performance**: `Plugin.trigger` is already called in the hot path (`text-end`). Adding it to `text-delta` adds per-token overhead. Mitigation: only invoke if any loaded plugin registers the hook (check at plugin load time, not per-token).

2. **Backward compatibility**: Plugins that don't register these hooks see zero change. The `output.abort` default is `undefined` (falsy), so existing behavior is preserved.

3. **Subsumes #9737**: The `tool-input-delta` handling naturally accumulates `state.raw`, which is exactly what #9737 requests.

4. **Complements #12472**: Claude Code's `PreToolUse`/`PostToolUse` map to `tool.execute.before/after`. These new hooks cover the streaming phase that Claude Code doesn't expose at all -- making OpenCode's plugin system strictly more capable.

5. **Complements #13524**: The centralized hook dispatch from #13524 would naturally include these new hooks.
