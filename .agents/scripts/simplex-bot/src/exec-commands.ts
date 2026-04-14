/**
 * SimpleX Bot — Exec/Approval Commands
 * Extracted from commands.ts to reduce file-level complexity.
 */

import type { CommandContext, CommandDefinition } from "./types";
import { ApprovalManager, executeShellCommand } from "./approval";

let approvalManager = new ApprovalManager();

export function setApprovalManager(manager: ApprovalManager): void {
  approvalManager = manager;
}

export function getApprovalManager(): ApprovalManager {
  return approvalManager;
}

export const runCommand: CommandDefinition = {
  name: "run",
  description: "Execute a command remotely (approval required for unsafe commands)",
  groupEnabled: false,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const command = ctx.args.join(" ");
    if (!command) {
      return "Usage: /run [command]\\nExample: /run aidevops status";
    }

    const contactId = ctx.contact?.contactId;
    const contactName = ctx.contact?.localDisplayName ?? "unknown";
    if (contactId === undefined) {
      return "Cannot execute commands: no contact identity available.";
    }

    const classification = approvalManager.classify(command);

    switch (classification) {
      case "blocked":
        return "BLOCKED: This command matches a blocked pattern and cannot be executed.\\nCommand: " + command;

      case "allowed": {
        const result = await executeShellCommand(command);
        const lines = ["Executed (allowlisted):", ""];
        if (result.stdout) lines.push(result.stdout);
        if (result.stderr) lines.push("stderr: " + result.stderr);
        lines.push("", "Exit code: " + result.exitCode);
        return lines.join("\\n");
      }

      case "approval-required": {
        const request = approvalManager.createRequest(command, contactId, contactName, ctx.reply);
        return [
          "Approval required for command execution.",
          "", "Command: " + command,
          "Request ID: " + request.id,
          "Timeout: " + approvalManager.formatTimeout(),
          "", "To approve:  /approve " + request.id,
          "To reject:   /reject " + request.id,
          "To list all: /pending",
        ].join("\\n");
      }
    }
  },
};

export const approveCommand: CommandDefinition = {
  name: "approve",
  description: "Approve a pending command execution",
  groupEnabled: false,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const requestId = ctx.args[0];
    if (!requestId) return "Usage: /approve [request-id]";

    const contactId = ctx.contact?.contactId;
    if (contactId === undefined) return "Cannot approve: no contact identity available.";

    const request = approvalManager.approve(requestId, contactId);
    if (!request) {
      const existing = approvalManager.getRequest(requestId);
      if (existing) return "Request [" + requestId + "] is no longer pending (state: " + existing.state + ").";
      return "No pending request found with ID: " + requestId;
    }

    await ctx.reply("Approved. Executing: " + request.command);
    const result = await executeShellCommand(request.command);
    const lines = ["Result for [" + requestId + "]:", ""];
    if (result.stdout) lines.push(result.stdout);
    if (result.stderr) lines.push("stderr: " + result.stderr);
    lines.push("", "Exit code: " + result.exitCode);
    return lines.join("\\n");
  },
};

export const rejectCommand: CommandDefinition = {
  name: "reject",
  description: "Reject a pending command execution",
  groupEnabled: false,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const requestId = ctx.args[0];
    if (!requestId) return "Usage: /reject [request-id]";
    const request = approvalManager.reject(requestId);
    if (!request) return "No pending request found with ID: " + requestId;
    return "Rejected command [" + requestId + "]: " + request.command;
  },
};

export const pendingCommand: CommandDefinition = {
  name: "pending",
  description: "List pending command approval requests",
  groupEnabled: false,
  dmEnabled: true,
  handler: async (ctx: CommandContext): Promise<string> => {
    const contactId = ctx.contact?.contactId;
    const requests = approvalManager.listPending(contactId);
    if (requests.length === 0) return "No pending approval requests.";

    const lines = ["Pending approval requests:", ""];
    for (const req of requests) {
      const ageSeconds = Math.round((Date.now() - req.createdAt) / 1000);
      lines.push("[" + req.id + "] " + req.command + " (" + ageSeconds + "s ago)");
    }
    lines.push("", "Use /approve <id> or /reject <id> to respond.");
    return lines.join("\\n");
  },
};
