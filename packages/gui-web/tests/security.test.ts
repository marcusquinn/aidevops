import { describe, expect, test } from "bun:test";
import { containsSecretSentinel } from "../../gui-shared/src";
import { mockedStatus } from "../src/status-client";
import { renderDashboardHtml } from "../src/dashboard";

describe("dashboard redaction", () => {
  test("rendered shell excludes secret sentinel values", () => {
    const html = renderDashboardHtml(mockedStatus());

    expect(containsSecretSentinel(html)).toBe(false);
  });
});
