import { describe, expect, test } from "bun:test";
import { buildStatusNotifications, classifyToastLine, statusFixture } from "../src";

describe("notification logic", () => {
  test("classifies OpenCode toast lines with the same severity ordering", () => {
    expect(classifyToastLine("[SECURITY ADVISORY] rotate token")).toBe("error");
    expect(classifyToastLine("[WARN] GitHub CLI prerequisite requires gh >= 2.51.0")).toBe("warning");
    expect(classifyToastLine("Security: all protections active")).toBe("success");
    expect(classifyToastLine("aidevops v3.29.0 running in OpenCode v1.17.11")).toBe("info");
    expect(classifyToastLine("UPDATE_AVAILABLE|3.30.0")).toBeNull();
  });

  test("builds colourable notification records and GUI action metadata", () => {
    const notifications = buildStatusNotifications({
      aiApps: statusFixture.ai_apps,
      greetingOutput: [
        "[SECURITY ADVISORY] Test advisory",
        "[OPENCODE MAINTENANCE] Archive recommended",
        "Security: all protections active",
      ].join("\n"),
      oauthPool: statusFixture.oauth_pool,
      restartRequired: true,
      setupTargets: statusFixture.setup_targets,
    });

    expect(notifications.map((notification) => notification.severity)).toContain("error");
    expect(notifications.map((notification) => notification.severity)).toContain("warning");
    expect(notifications.map((notification) => notification.severity)).toContain("success");
    expect(notifications.some((notification) => notification.actions.some((action) => action.kind === "surface" && action.enabled))).toBe(true);
    expect(notifications.find((notification) => notification.id === "gui-restart-required")?.status).toBe("active");
  });
});
