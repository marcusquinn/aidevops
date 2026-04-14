/**
 * SimpleX Bot Command Router — parses and dispatches commands.
 * Extracted from index.ts to reduce file-level complexity.
 */

import type { CommandDefinition } from "./types";

/** Routes incoming messages to registered command handlers */
export class CommandRouter {
  private commands: Map<string, CommandDefinition> = new Map();

  register(cmd: CommandDefinition): void {
    this.commands.set(cmd.name.toLowerCase(), cmd);
  }

  registerAll(cmds: CommandDefinition[]): void {
    for (const cmd of cmds) {
      this.register(cmd);
    }
  }

  get(name: string): CommandDefinition | undefined {
    return this.commands.get(name.toLowerCase());
  }

  list(): CommandDefinition[] {
    return Array.from(this.commands.values());
  }

  parse(text: string): { command: string; args: string[] } | null {
    const trimmed = text.trim();
    if (!trimmed.startsWith("/")) return null;
    const parts = trimmed.slice(1).split(/\\s+/);
    const command = parts[0]?.toLowerCase() ?? "";
    const args = parts.slice(1);
    return { command, args };
  }
}
