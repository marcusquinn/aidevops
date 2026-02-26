/**
 * SimpleX Bot — Starter Commands
 *
 * Built-in commands for the aidevops SimpleX bot.
 * Each command is a self-contained handler that receives a CommandContext.
 *
 * Reference: t1327.4 bot framework specification
 * Reference: t1327.10 exec approval flow
 */

import { resolve } from "node:path";
import type { CommandContext, CommandDefinition } from "./types";
import { ApprovalManager, executeShellCommand } from "./approval";
import pkg from "../package.json";

// =============================================================================
// Shared Approval Manager
// =============================================================================

/**
 * Singleton approval manager — shared across all command handlers.
 * Initialised with defaults; the bot can reconfigure via setApprovalManager().
 */
let approvalManager = new ApprovalManager();

/** Replace the approval manager (called by SimplexAdapter after config is loaded) */
export function setApprovalManager(manager: ApprovalManager): void {
  approvalManager = manager;
}

/** Get the current approval manager (for shutdown cleanup) */
export function getApprovalManager(): ApprovalManager {
  return approvalManager;
}

// =============================================================================
// Built-in Commands
// =============================================================================

/** Show available commands and usage instructions (generated dynamically) */
const helpCommand: CommandDefinition = {
  name: "help",
  description: "Show available commands and usage",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (_ctx: CommandContext): Promise<string> => {
    // Build help text dynamically from BUILTIN_COMMANDS so it never drifts
    const lines = ["Available commands:", ""];
    for (const cmd of BUILTIN_COMMANDS) {
      lines.push(`/${cmd.name} — ${cmd.description}`);
    }
    return lines.join("\n");
  },
};

/** Query aidevops CLI for system status */
const statusCommand: CommandDefinition = {
  name: "status",
  description: "Show aidevops system status",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (_ctx: CommandContext): Promise<string> => {
    try {
      const proc = Bun.spawn(["aidevops", "status"], {
        stdout: "pipe",
        stderr: "pipe",
      });
      const output = await new Response(proc.stdout).text();
      const stderrText = await new Response(proc.stderr).text();
      const exitCode = await proc.exited;
      if (exitCode !== 0) {
        const detail = stderrText.trim();
        return "Failed to get aidevops status." + (detail ? ` Error: ${detail}` : " Is aidevops installed?");
      }
      return output.trim() || "aidevops is running (no output)";
    } catch {
      return "aidevops CLI not available. Install from https://aidevops.sh";
    }
  },
};

/** Route a question to the AI model routing system */
const askCommand: CommandDefinition = {
  name: "ask",
  description: "Ask AI a question (routes to appropriate model tier)",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const question = ctx.args.join(" ");
    if (!question) {
      return "Usage: /ask [question]\nExample: /ask What is the status of issue #42?";
    }
    // Placeholder — in production this routes to the model routing system
    return (
      'Question received: "' +
      question +
      '"\n\n(AI model routing not yet connected. This is a scaffold.)'
    );
  },
};

/** List open tasks from TODO.md using configurable path */
const tasksCommand: CommandDefinition = {
  name: "tasks",
  description: "List open tasks from TODO.md",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (_ctx: CommandContext): Promise<string> => {
    try {
      const tasksFile =
        process.env.SIMPLEX_TASKS_FILE ??
        `${import.meta.dir}/../../../../TODO.md`;
      const todoPath = resolve(tasksFile);
      const proc = Bun.spawn(
        ["grep", "-c", "\\- \\[ \\]", todoPath],
        { stdout: "pipe", stderr: "pipe" },
      );
      // Read stdout/stderr before awaiting exit (consistent with statusCommand,
      // avoids pipe buffer deadlocks for verbose commands)
      const output = await new Response(proc.stdout).text();
      const stderrOutput = await new Response(proc.stderr).text();
      const exitCode = await proc.exited;

      if (exitCode === 0) {
        const count = output.trim();
        return "Open tasks: " + count + "\n\nUse /task <description> to create a new task.";
      } else if (exitCode === 1) {
        // grep returns 1 when no lines match — not an error
        return "Open tasks: 0\n\nUse /task <description> to create a new task.";
      } else {
        // grep returns >1 for actual errors (file not found, permission denied)
        console.error("[tasksCommand] grep failed (exit " + exitCode + "): " + stderrOutput);
        return "Could not read TODO.md";
      }
    } catch (err) {
      return "Could not read TODO.md: " + String(err);
    }
  },
};

/** Create a new task entry in TODO.md (DM only) */
const taskCommand: CommandDefinition = {
  name: "task",
  description: "Create a new task in TODO.md",
  groupEnabled: false,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const description = ctx.args.join(" ");
    if (!description) {
      return "Usage: /task [description]\nExample: /task Fix authentication bug in login page";
    }
    // Placeholder — in production this calls claim-task-id.sh and appends to TODO.md
    return (
      'Task noted: "' +
      description +
      '"\n\n(Task creation not yet connected to TODO.md pipeline. This is a scaffold.)'
    );
  },
};

/**
 * Execute a command remotely (DM only).
 *
 * Three-tier classification:
 *   - allowlist: executes immediately (e.g., "aidevops status")
 *   - approval-required: sends approval request, waits for /approve <id>
 *   - blocklist: always rejected (e.g., "rm -rf")
 */
const runCommand: CommandDefinition = {
  name: "run",
  description: "Execute a command remotely (approval required for unsafe commands)",
  groupEnabled: false,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const command = ctx.args.join(" ");
    if (!command) {
      return "Usage: /run [command]\nExample: /run aidevops status";
    }

    const contactId = ctx.contact?.contactId;
    const contactName = ctx.contact?.localDisplayName ?? "unknown";
    if (contactId === undefined) {
      return "Cannot execute commands: no contact identity available.";
    }

    const classification = approvalManager.classify(command);

    switch (classification) {
      case "blocked":
        return (
          "BLOCKED: This command matches a blocked pattern and cannot be executed.\n" +
          "Command: " + command
        );

      case "allowed": {
        // Execute immediately — command is on the allowlist
        const result = await executeShellCommand(command);
        const lines = ["Executed (allowlisted):", ""];
        if (result.stdout) {
          lines.push(result.stdout);
        }
        if (result.stderr) {
          lines.push("stderr: " + result.stderr);
        }
        lines.push("", "Exit code: " + result.exitCode);
        return lines.join("\n");
      }

      case "approval-required": {
        // Create pending approval request
        const request = approvalManager.createRequest(
          command,
          contactId,
          contactName,
          ctx.reply,
        );

        return [
          "Approval required for command execution.",
          "",
          "Command: " + command,
          "Request ID: " + request.id,
          "Timeout: " + approvalManager.formatTimeout(),
          "",
          "To approve:  /approve " + request.id,
          "To reject:   /reject " + request.id,
          "To list all: /pending",
        ].join("\n");
      }
    }
  },
};

/** Approve a pending command execution */
const approveCommand: CommandDefinition = {
  name: "approve",
  description: "Approve a pending command execution",
  groupEnabled: false,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const requestId = ctx.args[0];
    if (!requestId) {
      return "Usage: /approve [request-id]\nExample: /approve a3f7";
    }

    const contactId = ctx.contact?.contactId;
    if (contactId === undefined) {
      return "Cannot approve: no contact identity available.";
    }

    const request = approvalManager.approve(requestId, contactId);
    if (!request) {
      // Check if the request exists but is in a non-pending state
      const existing = approvalManager.getRequest(requestId);
      if (existing) {
        return "Request [" + requestId + "] is no longer pending (state: " + existing.state + ").";
      }
      return "No pending request found with ID: " + requestId;
    }

    // Execute the approved command
    await ctx.reply("Approved. Executing: " + request.command);

    const result = await executeShellCommand(request.command);
    const lines = ["Result for [" + requestId + "]:", ""];
    if (result.stdout) {
      lines.push(result.stdout);
    }
    if (result.stderr) {
      lines.push("stderr: " + result.stderr);
    }
    lines.push("", "Exit code: " + result.exitCode);
    return lines.join("\n");
  },
};

/** Reject a pending command execution */
const rejectCommand: CommandDefinition = {
  name: "reject",
  description: "Reject a pending command execution",
  groupEnabled: false,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const requestId = ctx.args[0];
    if (!requestId) {
      return "Usage: /reject [request-id]\nExample: /reject a3f7";
    }

    const request = approvalManager.reject(requestId);
    if (!request) {
      return "No pending request found with ID: " + requestId;
    }

    return "Rejected command [" + requestId + "]: " + request.command;
  },
};

/** List pending approval requests */
const pendingCommand: CommandDefinition = {
  name: "pending",
  description: "List pending command approval requests",
  groupEnabled: false,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const contactId = ctx.contact?.contactId;
    const requests = approvalManager.listPending(contactId);

    if (requests.length === 0) {
      return "No pending approval requests.";
    }

    const lines = ["Pending approval requests:", ""];
    for (const req of requests) {
      const ageSeconds = Math.round((Date.now() - req.createdAt) / 1000);
      lines.push(
        "[" + req.id + "] " + req.command + " (" + ageSeconds + "s ago)",
      );
    }
    lines.push("", "Use /approve <id> or /reject <id> to respond.");
    return lines.join("\n");
  },
};

/** Simple liveness check — returns "pong" */
const pingCommand: CommandDefinition = {
  name: "ping",
  description: "Check bot responsiveness",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (_ctx: CommandContext): Promise<string> => {
    return "pong";
  },
};

/** Report bot version from package.json */
const versionCommand: CommandDefinition = {
  name: "version",
  description: "Show bot version",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (_ctx: CommandContext): Promise<string> => {
    return "aidevops SimpleX Bot v" + pkg.version;
  },
};

// =============================================================================
// Command Registry
// =============================================================================

/** All built-in commands */
export const BUILTIN_COMMANDS: CommandDefinition[] = [
  helpCommand,
  statusCommand,
  askCommand,
  tasksCommand,
  taskCommand,
  runCommand,
  approveCommand,
  rejectCommand,
  pendingCommand,
  pingCommand,
  versionCommand,
];
