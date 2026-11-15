// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { hasInlineOutput } from "./bounded-operation-access.mjs";

const RECEIPT_SCHEMA = "aidevops.interactive-operation/v1";
const MAX_WAIT_MS = 60 * 1000;
const FINALIZING_SETTLE_MS = 5 * 1000;

function responseError(message) {
  return JSON.stringify({ schema: RECEIPT_SCHEMA, error: message });
}

function outputWindow(args) {
  return { offset: args.output_offset, limit: args.output_limit };
}

/**
 * t18953: a terminal start/status receipt carries its first output window, so
 * a short command costs one model turn instead of start -> status -> output.
 * Read failures stay visible on the receipt and never fail it.
 */
async function withInlineOutput(manager, receipt, args, context) {
  if (!hasInlineOutput(receipt)) return receipt;
  try {
    const result = await manager.output(receipt.operation_id, context, outputWindow(args));
    return {
      ...receipt,
      output: {
        offset: result.offset,
        limit: result.limit,
        output: result.output,
        output_redacted: result.output_redacted,
        output_truncated: result.output_truncated,
      },
    };
  } catch (error) {
    return { ...receipt, output_error: error?.message || "stored output retrieval failed" };
  }
}

async function startOperation(manager, args, context) {
  const started = await manager.start({
    command: args.command,
    cwd: args.cwd,
    budgetMs: Number(args.budget_seconds || 900) * 1000,
    killGraceMs: args.kill_grace_seconds === undefined ? undefined : Number(args.kill_grace_seconds) * 1000,
    progressIntervalMs: Number(args.progress_interval_seconds || 900) * 1000,
    restorationBudgetMs: Number(args.restoration_budget_seconds || 60) * 1000,
    restorationCommand: args.restoration_command,
  }, context);
  // Clamp rather than reject: the process is already running, and an error
  // here would lose its operation ID.
  const waitMs = Math.min(MAX_WAIT_MS, Math.max(0, Math.round(Number(args.wait_seconds) * 1000) || 0));
  if (waitMs === 0) return started;
  return manager.settle(started.operation_id, context, { waitMs });
}

async function statusOperation(manager, args, context) {
  const waitMs = Number(args.wait_seconds ?? 0) * 1000;
  const receipt = await manager.status(args.operation_id, context, { waitMs });
  // A wait woken by running -> finalizing is moments from terminal; settle so
  // the output can come back in this call.
  if (waitMs <= 0 || receipt.state !== "finalizing") return receipt;
  return manager.settle(args.operation_id, context, { waitMs: Math.min(FINALIZING_SETTLE_MS, Math.round(waitMs)) });
}

export function createBoundedInteractiveOperationTool(tool, z, manager) {
  return tool({
    description:
      "Start, inspect, retrieve output from, or cancel a bounded long-running command without blocking the interactive session. " +
      "For a command likely to finish within 60 seconds, pass start with wait_seconds (up to 60): a terminal result returns its first output window inline, so no status or output call is needed. " +
      "Otherwise start returns at once; status can wait up to 60 seconds for progress or a lifecycle transition; a terminal start or status receipt includes output (output_offset/output_limit, default 1/120, max 500 lines); use output only to page further. " +
      "Commands are argv arrays, remain confined to the active project root, and must not daemonize or create a new process session; " +
      "known detaching launchers such as pulse-wrapper.sh --command dispatch are rejected before spawn. " +
      "Owned descendants are drained when the command exits; post_exit_descendants_terminated=true means exit 0 is not liveness evidence for anything it launched. " +
      "Cancellation is session-owned and restoration evidence remains explicit. " +
      "Cancel ends only the local process group: a remote command started via ssh keeps running unless ssh allocates a TTY (-tt) and the command does not ignore SIGHUP, or the restoration command kills it remotely. " +
      "budget_seconds defaults to 900 (also when set to 0); other values are clamped to 0.01–86400 seconds (24 hours); budget_ms reports the effective limit. " +
      "Operations do not survive plugin disposal/reload, session deletion, or host shutdown; this is not a durable scheduler. " +
      "termination_cause reports the first observed stop cause, not the identity of an external signal sender. " +
      "Optional kill_grace_seconds allows up to 300 seconds for TERM cleanup (default 0.5 seconds). " +
      "Only AIDEVOPS_PROGRESS: lines count as progress; overdue progress is diagnostic only and never shortens the budget.",
    args: {
      action: z.enum(["start", "status", "output", "cancel"]),
      operation_id: z.string().optional(),
      wait_seconds: z.number().optional(),
      output_offset: z.number().optional(),
      output_limit: z.number().optional(),
      command: z.array(z.string()).optional(),
      cwd: z.string().optional(),
      budget_seconds: z.number().optional(),
      kill_grace_seconds: z.number().optional(),
      progress_interval_seconds: z.number().optional(),
      restoration_budget_seconds: z.number().optional(),
      restoration_command: z.array(z.string()).optional(),
    },
    async execute(args, context) {
      try {
        let receipt;
        if (args.action === "start") {
          receipt = await withInlineOutput(manager, await startOperation(manager, args, context), args, context);
        } else if (args.action === "status") {
          receipt = await withInlineOutput(manager, await statusOperation(manager, args, context), args, context);
        } else if (args.action === "output") {
          receipt = await manager.output(args.operation_id, context, outputWindow(args));
        } else if (args.action === "cancel") {
          receipt = manager.cancel(args.operation_id, context);
        } else {
          return responseError("unknown action");
        }
        return JSON.stringify(receipt);
      } catch (error) {
        return responseError(error?.message || "bounded operation failed");
      }
    },
  });
}
