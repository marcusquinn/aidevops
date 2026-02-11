import { existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";

const HOME = homedir();

/**
 * Create the shell.env hook handler.
 *
 * Injects environment variables into shell commands executed by OpenCode.
 * This ensures aidevops scripts and tools have the correct paths and
 * configuration without requiring the user to set them manually.
 */
export function createShellEnvHook() {
  return (): Record<string, string> => {
    const env: Record<string, string> = {};

    // Core aidevops paths
    const agentsDir = join(HOME, ".aidevops", "agents");
    const scriptsDir = join(agentsDir, "scripts");
    const workspaceDir = join(HOME, ".aidevops", ".agent-workspace");

    if (existsSync(agentsDir)) {
      env.AIDEVOPS_AGENTS_DIR = agentsDir;
    }

    if (existsSync(scriptsDir)) {
      env.AIDEVOPS_SCRIPTS_DIR = scriptsDir;

      // Ensure scripts dir is on PATH for direct invocation
      const currentPath = process.env.PATH ?? "";
      if (!currentPath.includes(scriptsDir)) {
        env.PATH = `${scriptsDir}:${currentPath}`;
      }
    }

    if (existsSync(workspaceDir)) {
      env.AIDEVOPS_WORKSPACE_DIR = workspaceDir;
    }

    // Config directory
    const configDir = join(HOME, ".config", "aidevops");
    if (existsSync(configDir)) {
      env.AIDEVOPS_CONFIG_DIR = configDir;
    }

    // Credentials file (if it exists)
    const credentialsFile = join(configDir, "credentials.sh");
    if (existsSync(credentialsFile)) {
      env.AIDEVOPS_CREDENTIALS_FILE = credentialsFile;
    }

    return env;
  };
}
