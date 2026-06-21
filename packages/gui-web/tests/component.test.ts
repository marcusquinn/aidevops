import { describe, expect, test } from "bun:test";
import { mockedStatus } from "../src/status-client";
import { renderDashboardHtml } from "../src/dashboard";

describe("dashboard shell", () => {
  test("renders setup/status placeholders", () => {
    const html = renderDashboardHtml(mockedStatus());

    expect(html).toContain("aidevops control plane");
    expect(html).toContain("Read-only local dashboard scaffold");
    expect(html).toContain("Theme follows system preferences");
    expect(html).toContain("GUI app");
    expect(html).toContain("Repos");
    expect(html).toContain("Settings");
    expect(html).toContain("Capabilities");
    expect(html).toContain("Secret references");
  });
});
