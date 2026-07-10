import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { join } from "path";

export function checkCanonicalGitSafetyGate(command, scriptsDir, cwd = process.cwd()) {
  if (typeof command !== "string" || !command.includes("git")) return;
  const guard = join(scriptsDir, "canonical-git-command-guard.py");
  if (!existsSync(guard)) {
    throw new Error("BLOCKED: canonical Git guard is missing; refusing Git command");
  }
  try {
    execFileSync("python3", [guard, "--cwd", cwd, "--command", command], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 10000,
    });
  } catch (error) {
    const detail = error?.stderr?.toString().trim() || error?.message || "policy check failed";
    throw new Error(detail);
  }
}
