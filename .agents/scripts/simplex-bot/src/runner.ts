/**
 * SimpleX Bot — Runner Dispatch Bridge
 *
 * Bridges bot commands to the aidevops runner system.
 * Dispatches tasks to runner-helper.sh for execution,
 * with output capture and timeout handling.
 *
 * Reference: t1327.4 bot framework specification
 */

import { resolve } from "node:path";
import { homedir } from "node:os";

/** Runner dispatch result */
export interface RunnerResult {
  /** Whether the command succeeded */
  success: boolean;
  /** Command output (stdout) */
  output: string;
  /** Error output (stderr) */
  error: string;
  /** Exit code */
  exitCode: number;
  /** Execution time in milliseconds */
  durationMs: number;
}

/** Commands that are safe to execute without approval */
const SAFE_COMMANDS: ReadonlySet<string> = new Set([
  "aidevops status",
  "aidevops repos",
  "aidevops features",
  "aidevops skills",
]);

/** Maximum output length to return via chat (characters) */
const MAX_OUTPUT_LENGTH = 4000;

/** Default command timeout (30 seconds) */
const DEFAULT_TIMEOUT_MS = 30_000;

/**
 * Check whether a command is in the safe allowlist.
 * Safe commands can be executed without explicit approval.
 */
export function isSafeCommand(command: string): boolean {
  const normalized = command.trim().toLowerCase();
  return SAFE_COMMANDS.has(normalized);
}

/**
 * Execute an aidevops CLI command via Bun.spawn.
 * Returns structured result with output, error, and timing.
 */
export async function executeCommand(
  command: string,
  timeoutMs: number = DEFAULT_TIMEOUT_MS,
): Promise<RunnerResult> {
  const startTime = Date.now();

  try {
    // Split command into parts for spawn
    const parts = command.trim().split(/\s+/);
    if (parts.length === 0) {
      return {
        success: false,
        output: "",
        error: "Empty command",
        exitCode: 1,
        durationMs: 0,
      };
    }

    const proc = Bun.spawn(parts, {
      stdout: "pipe",
      stderr: "pipe",
      cwd: homedir(),
      env: {
        ...process.env,
        // Ensure aidevops scripts can find their config
        HOME: homedir(),
      },
    });

    // Race between command completion and timeout
    const timeoutPromise = new Promise<"timeout">((resolve) => {
      setTimeout(() => resolve("timeout"), timeoutMs);
    });

    const result = await Promise.race([
      proc.exited.then(() => "done" as const),
      timeoutPromise,
    ]);

    if (result === "timeout") {
      proc.kill();
      return {
        success: false,
        output: "",
        error: `Command timed out after ${timeoutMs}ms`,
        exitCode: 124,
        durationMs: Date.now() - startTime,
      };
    }

    const output = await new Response(proc.stdout).text();
    const error = await new Response(proc.stderr).text();
    const exitCode = await proc.exited;

    return {
      success: exitCode === 0,
      output: truncateOutput(output),
      error: truncateOutput(error),
      exitCode,
      durationMs: Date.now() - startTime,
    };
  } catch (err) {
    return {
      success: false,
      output: "",
      error: String(err),
      exitCode: 1,
      durationMs: Date.now() - startTime,
    };
  }
}

/**
 * Format a runner result for display in chat.
 * Includes exit code, timing, and truncated output.
 */
export function formatResult(result: RunnerResult): string {
  const lines: string[] = [];

  if (result.success) {
    lines.push(`Exit: 0 (${result.durationMs}ms)`);
  } else {
    lines.push(`Exit: ${result.exitCode} (${result.durationMs}ms)`);
  }

  if (result.output.trim()) {
    lines.push("");
    lines.push(result.output.trim());
  }

  if (result.error.trim() && !result.success) {
    lines.push("");
    lines.push(`Error: ${result.error.trim()}`);
  }

  return lines.join("\n");
}

/** Truncate output to fit chat message limits */
function truncateOutput(text: string): string {
  if (text.length <= MAX_OUTPUT_LENGTH) {
    return text;
  }
  return (
    text.substring(0, MAX_OUTPUT_LENGTH) +
    `\n\n... (truncated, ${text.length - MAX_OUTPUT_LENGTH} chars omitted)`
  );
}
