/**
 * SimpleX Bot — Starter Commands
 *
 * Built-in commands for the aidevops SimpleX bot.
 * Each command is a self-contained handler that receives a CommandContext.
 *
 * Reference: t1327.4 bot framework specification
 */

import type { CommandContext, CommandDefinition } from "./types";
import pkg from "../package.json";

// =============================================================================
// Built-in Commands
// =============================================================================

const helpCommand: CommandDefinition = {
  name: "help",
  description: "Show available commands and usage",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    return [
      "Available commands:",
      "",
      "/help — Show this help message",
      "/status — Show aidevops system status",
      "/ask <question> — Ask AI a question",
      "/tasks — List open tasks",
      "/task <description> — Create a new task",
      "/run <command> — Execute an aidevops CLI command",
      "/ping — Check bot responsiveness",
      "/version — Show bot version",
    ].join("\n");
  },
};

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
      const exitCode = await proc.exited;
      if (exitCode !== 0) {
        return "Failed to get aidevops status. Is aidevops installed?";
      }
      return output.trim() || "aidevops is running (no output)";
    } catch {
      return "aidevops CLI not available. Install from https://aidevops.sh";
    }
  },
};

const askCommand: CommandDefinition = {
  name: "ask",
  description: "Ask AI a question (routes to appropriate model tier)",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const question = ctx.args.join(" ");
    if (!question) {
      return "Usage: /ask <question>\nExample: /ask What is the status of issue #42?";
    }
    // Placeholder — in production this routes to the model routing system
    return `Question received: "${question}"\n\n(AI model routing not yet connected. This is a scaffold — connect to your preferred AI provider.)`;
  },
};

const tasksCommand: CommandDefinition = {
  name: "tasks",
  description: "List open tasks from TODO.md",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (_ctx: CommandContext): Promise<string> => {
    try {
      const tasksFile =
        process.env.SIMPLEX_TASKS_FILE ||
        `${import.meta.dir}/../../../..` + "/TODO.md";
      const { resolve } = await import("node:path");
      const todoPath = resolve(tasksFile);
      const proc = Bun.spawn(
        [
          "bash",
          "-c",
          `grep -c '\\- \\[ \\]' "${todoPath}" 2>/dev/null || echo 0`,
        ],
        { stdout: "pipe", stderr: "pipe" },
      );
      const count = (await new Response(proc.stdout).text()).trim();
      return `Open tasks: ${count}\n\nUse /task <description> to create a new task.`;
    } catch (err) {
      return `Could not read TODO.md: ${String(err)}`;
    }
  },
};

const taskCommand: CommandDefinition = {
  name: "task",
  description: "Create a new task in TODO.md",
  groupEnabled: false,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const description = ctx.args.join(" ");
    if (!description) {
      return "Usage: /task <description>\nExample: /task Fix authentication bug in login page";
    }
    // Placeholder — in production this calls claim-task-id.sh and appends to TODO.md
    return `Task noted: "${description}"\n\n(Task creation not yet connected to TODO.md pipeline. This is a scaffold.)`;
  },
};

const runCommand: CommandDefinition = {
  name: "run",
  description: "Execute an aidevops CLI command remotely",
  groupEnabled: false,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const command = ctx.args.join(" ");
    if (!command) {
      return "Usage: /run <command>\nExample: /run aidevops status";
    }
    // Security: this should go through exec approval flow (t1327.10)
    return [
      `Command: ${command}`,
      "",
      "Remote command execution requires approval (t1327.10).",
      "Safe commands (/status, /tasks) can be allowlisted.",
      "This is a scaffold — exec approval flow not yet implemented.",
    ].join("\n");
  },
};

const pingCommand: CommandDefinition = {
  name: "ping",
  description: "Check bot responsiveness",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (_ctx: CommandContext): Promise<string> => {
    return "pong";
  },
};

const versionCommand: CommandDefinition = {
  name: "version",
  description: "Show bot version",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (_ctx: CommandContext): Promise<string> => {
    return `aidevops SimpleX Bot v${pkg.version}`;
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
  pingCommand,
  versionCommand,
];
