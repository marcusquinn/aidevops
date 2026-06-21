import { assertNoSecretSentinels, type GuiResponseEnvelope, type GuiStatusData } from "../../gui-shared/src";

export function renderDashboardHtml(status: GuiResponseEnvelope<GuiStatusData>): string {
  assertNoSecretSentinels(status);

  const paths = status.data.paths
    .map((path) => `<li><strong>${escapeHtml(path.label)}</strong>: ${escapeHtml(path.health)} <code>${escapeHtml(path.path_ref)}</code></li>`)
    .join("");
  const helpers = status.data.helper_availability
    .map((helper) => `<li>${escapeHtml(helper.name)}: ${escapeHtml(helper.status)}</li>`)
    .join("");
  const secrets = status.data.secrets
    .map((secret) => `<li>${escapeHtml(secret.name)}: ${escapeHtml(secret.status)}</li>`)
    .join("");

  return `<section aria-label="aidevops status"><h1>aidevops control plane</h1><p>Read-only local dashboard scaffold.</p><dl><dt>Version</dt><dd>${escapeHtml(status.data.aidevops_version)}</dd><dt>API</dt><dd>${escapeHtml(status.data.runtime.api)}</dd></dl><h2>Path health</h2><ul>${paths}</ul><h2>Helper availability</h2><ul>${helpers}</ul><h2>Secret references</h2><ul>${secrets}</ul><p>${escapeHtml(status.data.placeholders[0] ?? "More read-only adapters are planned.")}</p></section>`;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
