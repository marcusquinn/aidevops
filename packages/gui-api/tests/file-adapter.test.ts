import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "bun:test";
import { containsSecretSentinel } from "../../gui-shared/src";
import { readFileExplorer } from "../src/file-adapter";

const originalHome = process.env.HOME;
let tempHome: string | null = null;

afterEach(() => {
  process.env.HOME = originalHome;
  if (tempHome !== null) {
    rmSync(tempHome, { recursive: true, force: true });
    tempHome = null;
  }
});

describe("file adapter", () => {
  test("lists allowlisted agents files and previews markdown", () => {
    tempHome = join(tmpdir(), `aidevops-gui-file-test-${Date.now()}`);
    const agentsDir = join(tempHome, ".aidevops", "agents");
    mkdirSync(agentsDir, { recursive: true });
    writeFileSync(join(agentsDir, "AGENTS.md"), "# Test Agent\n\nSafe content.");
    process.env.HOME = tempHome;

    const response = readFileExplorer("agents", "AGENTS.md", "2026-06-21T00:00:00.000Z");

    expect(response.ok).toBe(true);
    expect(response.operation_id).toBe("filesystem.read");
    expect(response.data.entries.map((entry) => entry.name)).toContain("AGENTS.md");
    expect(response.data.selected_preview?.mode).toBe("markdown");
    expect(response.data.selected_preview?.content).toContain("Safe content");
    expect(containsSecretSentinel(response)).toBe(false);
  });

  test("blocks traversal outside the selected file root", () => {
    tempHome = join(tmpdir(), `aidevops-gui-file-test-${Date.now()}`);
    mkdirSync(join(tempHome, ".aidevops", "agents"), { recursive: true });
    process.env.HOME = tempHome;

    const response = readFileExplorer("agents", "../../.ssh", "2026-06-21T00:00:00.000Z");

    expect(response.ok).toBe(false);
    expect(response.errors).toContain("path_outside_root");
  });
});
