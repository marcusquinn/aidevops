import { describe, expect, test } from "bun:test";
import { mockedStatus } from "../src/status-client";
import { renderDashboardHtml } from "../src/dashboard";

describe("dashboard shell", () => {
  test("renders setup/status placeholders", () => {
    const html = renderDashboardHtml(mockedStatus());

    expect(html).toContain("aidevops app interface");
    expect(html).toContain("Read-only local app shell");
    expect(html).toContain("Operations");
    expect(html).toContain("Agents file explorer");
    expect(html).toContain("Local Setup");
    expect(html).toContain("Theme follows system preferences");
    expect(html).toContain("GUI app");
    expect(html).toContain("Installation");
    expect(html).toContain("Domains");
    expect(html).toContain("Servers");
    expect(html).toContain("Secret references");
  });
});
