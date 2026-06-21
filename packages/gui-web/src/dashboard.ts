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
  const repos = status.data.repos.repos
    .map((repo) => `<li>${escapeHtml(repo.name)}: ${escapeHtml(repo.platform)} ${escapeHtml(repo.local_path_status)}</li>`)
    .join("");
  const settings = status.data.settings.keys
    .map((key) => `<li>${escapeHtml(key)}</li>`)
    .join("");
  const capabilities = status.data.capabilities
    .map((capability) => `<li>${escapeHtml(capability.label)}: ${escapeHtml(capability.status)}</li>`)
    .join("");

  return `<section aria-label="aidevops status"><h1>aidevops control plane</h1><p>Read-only local control graph.</p><p>Surface library, canvas, and inspector structure follows an app-style node workflow.</p><p>Theme follows system preferences with light and dark overrides.</p><p>${escapeHtml(status.data.update.message)}</p><dl><dt>Version</dt><dd>${escapeHtml(status.data.aidevops_version)}</dd><dt>API</dt><dd>${escapeHtml(status.data.runtime.api)}</dd></dl><h2>Control graph</h2><ul><li>Setup</li><li>Projects</li><li>Automation</li><li>Integrations</li><li>Settings</li><li>Security</li></ul><h2>Path health</h2><ul>${paths}</ul><h2>Projects</h2><ul>${repos}</ul><h2>Settings</h2><ul>${settings}</ul><h2>Helper availability</h2><ul>${helpers}</ul><h2>Automation</h2><ul>${capabilities}</ul><h2>Secret references</h2><ul>${secrets}</ul><p>${escapeHtml(status.data.placeholders[0] ?? "More read-only adapters are planned.")}</p></section>`;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
