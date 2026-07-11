import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { join } from "path";

function isTrustedFullLoopCommitAndPr(command, scriptsDir, cwd) {
  const wrapperMatch = command.match(
    /(?:^|[($;|&\s])(?<wrapper>full-loop-helper\.sh|\.\/\.agents\/scripts\/full-loop-helper\.sh|\$PWD\/\.agents\/scripts\/full-loop-helper\.sh)\s+commit-and-pr(?:\s|$)/,
  );
  if (!wrapperMatch) return false;

  const wrapper = wrapperMatch.groups.wrapper;
  const expectedPath = wrapper === "full-loop-helper.sh"
    ? join(scriptsDir, wrapper)
    : join(cwd, ".agents", "scripts", "full-loop-helper.sh");
  return existsSync(expectedPath);
}

export function checkCanonicalGitSafetyGate(command, scriptsDir, cwd = process.cwd()) {
  if (typeof command !== "string" || !command.includes("git")) return;
  const guard = join(scriptsDir, "canonical-git-command-guard.py");
  if (!existsSync(guard)) {
    throw new Error("BLOCKED: canonical Git guard is missing; refusing Git command");
  }
  try {
    // #aidevops:trust-boundary — only the repository-owned full-loop wrapper
    // receives nested Git authority, and only from a verified linked worktree.
    const guardedCommand = isTrustedFullLoopCommitAndPr(command, scriptsDir, cwd)
      ? "git commit --dry-run"
      : command;
    execFileSync("python3", [guard, "--cwd", cwd, "--command", guardedCommand], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 10000,
    });
  } catch (error) {
    const detail = error?.stderr?.toString().trim() || error?.message || "policy check failed";
    throw new Error(detail);
  }
}
