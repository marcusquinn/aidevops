/**
 * OAuth Pool — MCP Tool (t2128 refactor)
 *
 * Tool definition for /model-accounts-pool. Action handlers and display
 * formatting are in oauth-pool-display.mjs.
 *
 * @module oauth-pool-tool
 */

import { getAccounts } from "./oauth-pool-storage.mjs";
import { resolveInjectFn } from "./oauth-pool.mjs";
import {
  poolActionList, poolActionRemove, poolActionStatus,
  poolActionResetCooldowns, poolActionRotate, poolActionAssignPending,
  poolActionCheck, poolActionSetPriority,
} from "./oauth-pool-display.mjs";

// ---------------------------------------------------------------------------
// Tool definition
// ---------------------------------------------------------------------------

export function createPoolTool(client) {
  return {
    description: "Manage OAuth account pool for provider credential rotation. Actions: list, rotate, remove, assign-pending, check, status, reset-cooldowns, set-priority. Providers: anthropic, openai, cursor, google. Shell equivalent: oauth-pool-helper.sh.",
    parameters: {
      type: "object",
      properties: {
        action: { type: "string", enum: ["list", "remove", "status", "reset-cooldowns", "rotate", "assign-pending", "check", "set-priority"], description: "Action to perform" },
        email: { type: "string", description: "Account email (for remove/assign-pending/set-priority)" },
        provider: { type: "string", enum: ["anthropic", "openai", "cursor", "google"], description: "Provider (default: anthropic)" },
        priority: { type: "integer", description: "Rotation priority for set-priority (higher = preferred; 0 = LRU)" },
      },
      required: ["action"],
    },
    async execute(args) {
      const provider = args.provider || "anthropic";
      const accounts = getAccounts(provider);
      const now = Date.now();
      const hints = {
        anthropic: 'run `opencode auth login` -> "Anthropic Pool"',
        openai: 'run `opencode auth login` -> "OpenAI Pool"',
        cursor: 'run `opencode auth login` -> "Cursor Pool"',
        google: 'run `opencode auth login` -> "Google Pool"',
      };
      const hint = `To add an account: ${hints[provider] || hints.anthropic}.`;
      const actions = {
        "list": () => poolActionList(provider, accounts, hint, now),
        "remove": () => poolActionRemove(provider, args.email),
        "status": () => poolActionStatus(provider, accounts, hint, now),
        "reset-cooldowns": () => poolActionResetCooldowns(provider),
        "rotate": () => poolActionRotate(client, provider, accounts, resolveInjectFn),
        "assign-pending": () => poolActionAssignPending(provider, accounts, args.email),
        "check": () => poolActionCheck(args.provider, now),
        "set-priority": () => poolActionSetPriority(provider, args.email, args.priority),
      };
      const handler = actions[args.action];
      return handler ? handler() : `Unknown action: ${args.action}. Available: ${Object.keys(actions).join(", ")}`;
    },
  };
}
