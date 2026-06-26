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
  const localRepos = status.data.local_repos.repos
    .map((repo) => `<li>${escapeHtml(repo.name)}: ${escapeHtml(repo.aidevops_version)} ${escapeHtml(repo.default_branch)}</li>`)
    .join("");
  const aiProviders = status.data.oauth_pool.providers
    .map((provider) => `<li>${escapeHtml(provider.provider)}: ${provider.available}/${provider.total} available</li>`)
    .join("");
  const setupTargets = status.data.setup_targets
    .map((target) => `<li>${escapeHtml(target.label)}: ${escapeHtml(target.installed_version)} → ${escapeHtml(target.latest_version)} ${target.needs_update ? "update" : "current"}</li>`)
    .join("");
  const aiApps = status.data.ai_apps
    .map((app) => `<li>${escapeHtml(app.name)}: ${escapeHtml(app.status)} ${escapeHtml(app.aidevops_version)} → ${escapeHtml(app.latest_version)}</li>`)
    .join("");
  const vaultCollections = status.data.vault.collections
    .map((collection) => `<li>${escapeHtml(collection.label)}: ${escapeHtml(collection.state)} ${escapeHtml(collection.preview_policy)}</li>`)
    .join("");
  const settings = status.data.settings.keys
    .map((key) => `<li>${escapeHtml(key)}</li>`)
    .join("");
  const capabilities = status.data.capabilities
    .map((capability) => `<li>${escapeHtml(capability.label)}: ${escapeHtml(capability.status)}</li>`)
    .join("");
  const navSections = [
    { heading: "Development", items: ["Local Repos", "Remote Repos", "Secrets", "AI Providers"] },
    { heading: "Operations", items: ["Dashboard", "Vault", "Agents file explorer", "Config", "Local Setup", "Routines"] },
    { heading: "Infrastructure", items: ["Devices", "VPNs & Proxies", "Apps", "Installation", "Registrars", "Hosts", "Servers"] },
    { heading: "Identities", items: ["Brands", "Domains", "Personas"] },
    { heading: "Sites", items: ["Websites", "Forums", "Social Media", "Marketplaces"] },
    { heading: "Management", items: ["Email Accounts", "Messaging Accounts", "Calendars", "Addressbooks", "Tasks", "Notebooks", "Bookmarks"] },
    { heading: "Documents", items: ["Inbox", "Campaigns", "Cases", "Config", "Feedback", "Knowledge", "Maintenance", "Performance", "Reports"] },
  ];
  const renderedNavSections = navSections
    .map(({ heading, items }) => `<h2>${escapeHtml(heading)}</h2><ul>${items.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul>`)
    .join("");

  return [
    `<section aria-label="aidevops status">`,
    `<h1>aidevops app interface</h1>`,
    `<p>Made for creators.</p>`,
    `<p>AI-assisted development workflows, code quality, and deployment automation.</p>`,
    `<p>Theme follows system preferences with light and dark overrides. Sidebar modes: DevOps and Comms. Appearance controls can be hidden or shown, and include editable Hue, icon Reset, Show borders toggle, Show counts toggle, Font size choices xs, s, m, lg, xl, and Font options: IBM Plex Mono, IBM Plex Sans, IBM Plex Serif, Inter, Menlo (default), Playpen Sans, Poppins, Source Sans, Source Serif, Tilt Neon, Ubuntu Mono. A desktop status bar shows local readiness, repo totals, secret reference count, provider accounts, and update state.</p>`,
    `<p>Secret references stay read-only and redacted.</p>`,
    `<p>Vault surfaces show padlock indicators. Encrypted by aidevops Vault; contents visible only when unlocked through app or authorised vault commands.</p>`,
    `<p>${escapeHtml(status.data.update.message)}</p>`,
    renderedNavSections,
    `<h2>Path health</h2><ul>${paths}</ul>`,
    `<h2>Installed aidevops targets</h2><ul>${setupTargets}</ul>`,
    `<h2>AI Apps</h2><ul>${aiApps}</ul>`,
    `<h2>Vault</h2><p>${escapeHtml(status.data.vault.status)} / ${escapeHtml(status.data.vault.setup_state)}</p><ul>${vaultCollections}</ul>`,
    `<h2>Local Repo Setup</h2><ul>${localRepos}</ul>`,
    `<h2>Remote Repos</h2><ul>${repos}</ul>`,
    `<h2>AI Provider Pools</h2><ul>${aiProviders}</ul>`,
    `<h2>Settings</h2><ul>${settings}</ul>`,
    `<h2>Helper availability</h2><ul>${helpers}</ul>`,
    `<h2>Secrets</h2><ul>${secrets}</ul>`,
    `<h2>Capabilities</h2><ul>${capabilities}</ul>`,
    `</section>`,
  ].join("");
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
