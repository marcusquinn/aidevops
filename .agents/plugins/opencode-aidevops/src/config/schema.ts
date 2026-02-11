import { z } from "zod";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";

/**
 * Zod schema for plugin configuration.
 * Loaded from ~/.config/opencode/aidevops-plugin.json if it exists,
 * otherwise uses sensible defaults.
 */
const configSchema = z.object({
  agentsDir: z
    .string()
    .default(join(homedir(), ".aidevops", "agents")),

  loadSubagents: z.boolean().default(true),

  disabledAgents: z.array(z.string()).default([]),

  hooks: z
    .object({
      compaction: z.boolean().default(true),
      shellEnv: z.boolean().default(true),
      chatContext: z.boolean().default(true),
    })
    .default({}),

  maxAgents: z.number().int().positive().default(500),

  excludeDirs: z
    .array(z.string())
    .default([
      "node_modules",
      ".git",
      "_archive",
      "configs",
      "templates",
      "plugins",
    ]),
});

export type PluginConfig = z.infer<typeof configSchema>;

/**
 * Load plugin configuration from disk or return defaults.
 * Config file: ~/.config/opencode/aidevops-plugin.json
 */
export function loadConfig(): PluginConfig {
  const configPath = join(
    homedir(),
    ".config",
    "opencode",
    "aidevops-plugin.json",
  );

  if (!existsSync(configPath)) {
    return configSchema.parse({});
  }

  try {
    const raw = readFileSync(configPath, "utf-8");
    return configSchema.parse(JSON.parse(raw));
  } catch {
    // Invalid config — fall back to defaults rather than crash
    return configSchema.parse({});
  }
}
