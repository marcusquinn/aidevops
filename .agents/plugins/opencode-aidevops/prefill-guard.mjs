// ---------------------------------------------------------------------------
// prefill-guard.mjs — Defensive "last message must be user" guard
//
// WHY THIS EXISTS
//
// Claude Opus/Sonnet 4.6 (and some Claude models served through
// OpenAI-compatible proxies like GitHub Copilot) reject requests where the
// last message is from the assistant with:
//
//   "This model does not support assistant message prefill.
//    The conversation must end with a user message."
//
// In opencode this state can occur in several ways:
//
//   1. Aborted / interrupted previous turn (issue #13768, PR #14772):
//      the aborted assistant message has `finish` undefined, so the
//      continuation gate in `session/prompt.ts` fails — it requires
//      `lastAssistant2?.finish && !["tool-calls"].includes(...)` — and the
//      next iteration calls the LLM with a trailing assistant still present.
//
//   2. Continuation loop bug (issue #17982, PR #16921): opencode 1.3.17 has
//      a gate that mostly handles this, but only when `finish` is set.
//      Edge cases where finish is missing slip through.
//
//   3. Max-steps hint (PR #14772): when max steps is reached, opencode
//      appends `{role: "assistant", content: max_steps_default}` AFTER the
//      plugin hook runs. We can't strip this one from the plugin, but the
//      other cases are all fixable here.
//
//   4. WebUI / mobile edge cases where the DB state drifts from the UI's
//      view of the conversation.
//
// Upstream PRs #14772, #16921, and #18091 all add `stripTrailingAssistant()`
// inside `normalizeMessages()` in `provider/transform.ts`. None are merged
// as of 1.3.17 / 1.4.0. This hook applies the same logic at the plugin level.
//
// WHERE IT RUNS
//
// The `experimental.chat.messages.transform` hook is triggered from
// `session/prompt.ts` at (approximately, in 1.3.17's compiled output):
//
//     yield* plugin.trigger("experimental.chat.messages.transform", {},
//                           { messages: msgs });
//     const [skills, env4, instructions, modelMsgs] = yield* Effect.all([
//       ...,
//       Effect.promise(() => MessageV2.toModelMessages(msgs, model))
//     ]);
//     const result6 = yield* handle2.process({ messages: [...modelMsgs, ...], ... });
//
// The `msgs` array we mutate here is the same one converted to ModelMessages
// and sent to the LLM. Mutations via `output.messages.length = N` and
// `output.messages.pop()` propagate to the caller because the hook is a
// sync-ish mutation, not a replacement.
//
// SAFETY
//
// - We NEVER touch the session database. Stripped messages are still
//   displayed to the user in the transcript; we only modify the outgoing
//   LLM payload.
//
// - We preserve assistant messages whose `finish === "tool-calls"` or whose
//   parts contain an in-progress tool call — these messages are legitimate
//   mid-turn state and the next LLM call needs to see them to continue.
//
// - We leave at least one message in the array. If every message is an
//   assistant message (shouldn't happen, but defensively) we log a warning
//   and return without stripping so opencode's own error handling fires.
//
// - All work is wrapped in try/catch so a bug here can never break the
//   entire plugin hook chain.
//
// ---------------------------------------------------------------------------

/**
 * Determine whether an assistant message is safe to strip.
 *
 * Safe to strip when:
 *   - The message has no parts, OR
 *   - `finish` is NOT "tool-calls" AND the parts do not contain any active
 *     (non-errored, non-completed) tool call.
 *
 * Unsafe to strip (preserve) when:
 *   - `finish === "tool-calls"` — the LLM requested tools, next call needs
 *     to provide tool results.
 *   - Any tool part is in `pending` / `running` / `completed` state — the
 *     LLM response flow is mid-turn and dropping the call would desync.
 *
 * @param {{ info?: { role?: string, finish?: string }, parts?: Array<object> }} msg
 * @returns {boolean}
 */
function isAssistantSafeToStrip(msg) {
  if (!msg || msg.info?.role !== "assistant") return false;

  const finish = msg.info?.finish;
  if (finish === "tool-calls") return false;

  if (Array.isArray(msg.parts)) {
    for (const part of msg.parts) {
      if (!part || part.type !== "tool") continue;
      const status = part.state?.status;
      // `error` and `aborted` tool parts are terminal and OK to strip;
      // `pending`, `running`, `completed` indicate live state.
      if (
        status === "pending" ||
        status === "running" ||
        status === "completed"
      ) {
        return false;
      }
    }
  }

  return true;
}

/**
 * Build a compact one-line diagnostic for a stripped assistant message.
 *
 * @param {object} msg
 * @returns {string}
 */
function describeStripped(msg) {
  const info = msg.info || {};
  const provider = info.providerID || "?";
  const model = info.modelID || "?";
  const finish = info.finish || "none";
  const err = info.error?.name || info.error?.data?.message;
  const parts = Array.isArray(msg.parts) ? msg.parts.length : 0;
  const base = `${provider}/${model} finish=${finish} parts=${parts}`;
  return err ? `${base} error=${String(err).slice(0, 60)}` : base;
}

/**
 * Create the prefill guard hook.
 *
 * @param {{ qualityLog?: (level: string, message: string) => void }} [deps]
 * @returns {(input: object, output: { messages: Array<object> }) => Promise<void>}
 */
export function createPrefillGuardHook(deps = {}) {
  const { qualityLog } = deps;

  function log(level, msg) {
    if (qualityLog) {
      qualityLog(level, `prefill-guard: ${msg}`);
    } else {
      const prefix = level === "ERROR" ? "[aidevops prefill-guard ERROR]"
        : level === "WARN" ? "[aidevops prefill-guard WARN]"
        : "[aidevops prefill-guard]";
      console.error(`${prefix} ${msg}`);
    }
  }

  return async function prefillGuardHook(_input, output) {
    try {
      if (!output || !Array.isArray(output.messages)) return;
      const msgs = output.messages;
      if (msgs.length === 0) return;

      const last = msgs[msgs.length - 1];
      if (!last || last.info?.role !== "assistant") return;

      // Walk backwards, collecting assistant messages we can safely strip.
      const stripped = [];
      while (msgs.length > 1) {
        const candidate = msgs[msgs.length - 1];
        if (!isAssistantSafeToStrip(candidate)) break;
        stripped.push(candidate);
        msgs.pop();
      }

      if (stripped.length === 0) {
        // Last message IS an assistant but we couldn't safely strip it
        // (e.g. it has active tool calls). Log and let it through — the
        // upstream behaviour stays the same and if the provider rejects it,
        // that's a separate problem we shouldn't mask.
        log(
          "WARN",
          `last message is assistant but NOT safe to strip (${describeStripped(last)}); leaving untouched`,
        );
        return;
      }

      // Edge case: if after stripping the array is empty or has only
      // non-user messages, put the first one back to keep opencode's own
      // validation happy. This shouldn't happen in practice.
      if (msgs.length === 0) {
        const restored = stripped.pop();
        msgs.push(restored);
        log(
          "WARN",
          "stripping would have emptied message list; restored the last assistant",
        );
      }

      const details = stripped.map(describeStripped).join(" | ");
      log(
        "INFO",
        `stripped ${stripped.length} trailing assistant message(s) to avoid Claude prefill error: ${details}`,
      );
    } catch (err) {
      // Never let this hook break the chain.
      const msg = err instanceof Error ? err.message : String(err);
      log("ERROR", `exception in prefill guard: ${msg}`);
    }
  };
}
