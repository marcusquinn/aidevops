import type { GuiStatusData } from "@aidevops/gui-shared";
import type { ReactElement } from "react";

export function DesktopStatusBar({ status }: { status: GuiStatusData }): ReactElement {
  const version = status.update.installed_version !== "unknown" ? status.update.installed_version : status.aidevops_version;
  const versionLabel = version === "unknown" || version.startsWith("v") ? version : `v${version}`;
  const needsUpdate = status.setup_targets.filter((target) => target.needs_update).length + status.ai_apps.filter((app) => app.needs_update).length;
  const oauthAccounts = status.oauth_pool.providers.reduce((total, provider) => total + provider.total, 0);
  const localRepoCount = status.local_repos.total || status.local_repos.repos.length;
  const remoteRepoCount = status.repos.total || status.repos.repos.length;
  const statusLabel = status.update.restart_required ? "Restart required" : "Ready";
  const vaultLabel = status.vault?.unlocked ? "Vault unlocked" : `Vault ${status.vault?.status ?? "unknown"}`;

  return (
    <div className="desktop-status-bar" role="status">
      <span className={status.update.restart_required ? "status-dot warn" : "status-dot"} aria-hidden="true" />
      <strong>{statusLabel}</strong>
      <span>Read-only local GUI</span>
      <span>{versionLabel}</span>
      <span>{localRepoCount} local repos</span>
      <span>{remoteRepoCount} remote repos</span>
      <span>{status.secrets.length} secrets</span>
      <span>{vaultLabel}</span>
      <span>{oauthAccounts} provider accounts</span>
      <span>{needsUpdate} need update</span>
    </div>
  );
}
