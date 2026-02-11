import { execSync } from "child_process";

/**
 * Tool definition for exposing the aidevops CLI as an OpenCode tool.
 *
 * This allows the AI to invoke aidevops commands directly through the
 * plugin's tool interface rather than via bash.
 */
export function createAidevopsCliTool() {
  return {
    name: "aidevops",
    description:
      "Run aidevops CLI commands (status, plugin, secret, repos, features, etc.)",
    parameters: {
      command: {
        type: "string" as const,
        description:
          "The aidevops subcommand to run (e.g., status, plugin list, repos)",
      },
    },
    handler: async (args: Record<string, unknown>): Promise<string> => {
      const command = typeof args.command === "string" ? args.command : "";

      if (!command) {
        return "Error: command parameter is required. Example: aidevops status";
      }

      // Security: block commands that could expose secrets
      const blocked = ["secret show", "secret get", "secret export"];
      for (const pattern of blocked) {
        if (command.includes(pattern)) {
          return `Error: '${pattern}' is blocked for security. Use 'aidevops secret set NAME' at the terminal instead.`;
        }
      }

      try {
        const result = execSync(`aidevops ${command}`, {
          encoding: "utf-8",
          timeout: 30000,
          stdio: ["pipe", "pipe", "pipe"],
        });
        return result.trim() || "(no output)";
      } catch (err: unknown) {
        const error = err as { stderr?: string; message?: string };
        return `Error running 'aidevops ${command}': ${error.stderr ?? error.message ?? "unknown error"}`;
      }
    },
  };
}

/**
 * Tool definition for running aidevops helper scripts.
 */
export function createHelperScriptTool() {
  return {
    name: "aidevops-helper",
    description:
      "Run an aidevops helper script (e.g., memory-helper.sh recall, mail-helper.sh check)",
    parameters: {
      script: {
        type: "string" as const,
        description:
          "Helper script name (e.g., memory-helper.sh, mail-helper.sh, supervisor-helper.sh)",
      },
      args: {
        type: "string" as const,
        description: "Arguments to pass to the script",
      },
    },
    handler: async (params: Record<string, unknown>): Promise<string> => {
      const script = typeof params.script === "string" ? params.script : "";
      const args = typeof params.args === "string" ? params.args : "";

      if (!script) {
        return "Error: script parameter is required. Example: memory-helper.sh recall";
      }

      // Validate script name (must end in .sh, no path traversal)
      if (!script.endsWith(".sh") || script.includes("/") || script.includes("..")) {
        return "Error: script must be a .sh filename without path separators";
      }

      // Security: block scripts that could expose secrets
      if (script.includes("credential") && args.includes("show")) {
        return "Error: credential display is blocked for security.";
      }

      const scriptsDir = `${process.env.HOME}/.aidevops/agents/scripts`;

      try {
        const result = execSync(`bash "${scriptsDir}/${script}" ${args}`, {
          encoding: "utf-8",
          timeout: 30000,
          stdio: ["pipe", "pipe", "pipe"],
        });
        return result.trim() || "(no output)";
      } catch (err: unknown) {
        const error = err as { stderr?: string; message?: string };
        return `Error running '${script} ${args}': ${error.stderr ?? error.message ?? "unknown error"}`;
      }
    },
  };
}
