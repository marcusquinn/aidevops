// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// OpenCode 2 probe plugin for context-budget-helper.sh. OpenCode 2 sends
// provider requests through its own transport, so the body is read from the
// public http.request hook. Plugin.define() is an identity function, so the
// plain definition object avoids an SDK dependency in this diagnostic package.
import { captureSettings, createCaptureWriter, isProviderRequest } from "../capture-common.mjs";

export const AidevopsContextBudgetCaptureV2 = {
  id: "aidevops-context-budget-capture",
  setup: async (ctx) => {
    const settings = captureSettings();
    if (!settings) return undefined;
    const writer = createCaptureWriter(settings);
    const registration = await ctx.session.hook("http.request", async (event) => {
      try {
        const request = event?.request;
        if (!writer.active || !(request instanceof Request) || !isProviderRequest(request.url)) return;
        writer.write(await request.clone().text());
      } catch {
        // Diagnostic only: never affect the provider request.
      }
    });
    return async () => {
      await registration?.dispose?.()?.catch?.(() => {});
    };
  },
};

export default AidevopsContextBudgetCaptureV2;
