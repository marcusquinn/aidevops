import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";

const HOME = homedir();
const WORKSPACE_DIR = join(HOME, ".aidevops", ".agent-workspace");

/**
 * Create the chat.message hook handler.
 *
 * Injects lightweight context into the first user message of a session.
 * This provides the AI with awareness of the aidevops framework state
 * without requiring the user to manually provide context.
 *
 * Only injects once per session (tracks via closure) and keeps the
 * injection minimal to avoid wasting tokens.
 */
export function createChatContextHook(directory: string) {
  let injected = false;

  return (
    _input: { content?: string; role?: string },
    output: { parts: Array<{ type: string; text: string }> },
  ): void => {
    // Only inject context on the first message
    if (injected) return;
    injected = true;

    const contextParts: string[] = [];

    // Check for active batch/task state
    const checkpointPath = join(WORKSPACE_DIR, "tmp", "session-checkpoint.md");
    if (existsSync(checkpointPath)) {
      try {
        const checkpoint = readFileSync(checkpointPath, "utf-8").trim();
        if (checkpoint.length > 0 && checkpoint.length < 2000) {
          contextParts.push(
            "[Session checkpoint detected — previous state available]",
          );
        }
      } catch {
        // ignore
      }
    }

    // Check for pending mail
    const mailDb = join(WORKSPACE_DIR, "mail", "mailbox.db");
    if (existsSync(mailDb)) {
      contextParts.push(
        "[Inter-agent mailbox active — check with mail-helper.sh]",
      );
    }

    // Detect if we're in a worktree
    const gitDir = join(directory, ".git");
    if (existsSync(gitDir)) {
      try {
        const gitContent = readFileSync(gitDir, "utf-8").trim();
        if (gitContent.startsWith("gitdir:")) {
          contextParts.push("[Working in a git worktree]");
        }
      } catch {
        // .git is a directory (normal repo), not a worktree — that's fine
      }
    }

    if (contextParts.length === 0) return;

    output.parts.push({
      type: "text",
      text: `\n\n---\n_aidevops context: ${contextParts.join(" | ")}_\n`,
    });
  };
}
