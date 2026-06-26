/* jshint esversion: 11 */
import type { ReactNode } from "react";
import type { GuiFileRootId, GuiStatusData } from "../../gui-shared/src";
import { SurfaceGlyph } from "./AppNavigation";
import type { SurfaceId, SurfaceNavItem } from "./app-model";
import { inventorySurfaceConfigs, text } from "./app-model";
import { FileExplorerSurface } from "./FileExplorerSurface";
import { AppsSurface, EditableInventorySurface, InstallationSurface } from "./InventorySurfaces";
import { AiProvidersSurface, LocalReposSurface, LockedVaultGate, OverviewSurface, PlannedSurface, ProjectsSurface, SecuritySurface, VaultSurface } from "./StatusSurfaces";
import { isVaultSurfaceLocked, vaultCollectionForSurface } from "./VaultBadges";

export function Workspace({ activeItem, activeSectionLabel, activeSurface, fileRoot, status }: {
  activeItem: SurfaceNavItem;
  activeSectionLabel: string;
  activeSurface: SurfaceId;
  fileRoot: GuiFileRootId | undefined;
  status: GuiStatusData;
}) {
  return (
    <section className="app-inset" aria-label={text.workspaceLabel}>
      <WorkspaceHeader activeItem={activeItem} activeSectionLabel={activeSectionLabel} version={displayVersion(status)} />
      <div className="workspace-scroll">
        <SurfaceContent activeItem={activeItem} activeSurface={activeSurface} fileRoot={fileRoot} status={status} />
      </div>
    </section>
  );
}

function WorkspaceHeader({ activeItem, activeSectionLabel, version }: {
  activeItem: SurfaceNavItem;
  activeSectionLabel: string;
  version: string;
}) {
  const versionLabel = version.startsWith("v") ? version : `v${version}`;

  return (
    <header className="workspace-header">
      <div className="header-title">
        <span className="workspace-surface-icon" aria-hidden="true"><SurfaceGlyph icon={activeItem.icon} /></span>
        <div>
          <p>{activeSectionLabel}</p>
          <h1>{activeItem.label}</h1>
        </div>
      </div>
      <div className="header-actions">
        <label className="workspace-search">
          <span>⌘K</span>
          <input disabled placeholder={text.searchPlaceholder} />
        </label>
        <span className="version-pill" title={`aidevops version ${versionLabel}`}>{versionLabel}</span>
      </div>
    </header>
  );
}

function displayVersion(status: GuiStatusData): string {
  if (status.update.installed_version !== "unknown") {
    return status.update.installed_version;
  }

  return status.aidevops_version;
}

function SurfaceContent({ activeItem, activeSurface, fileRoot, status }: {
  activeItem: SurfaceNavItem;
  activeSurface: SurfaceId;
  fileRoot: GuiFileRootId | undefined;
  status: GuiStatusData;
}) {
  const inventoryConfig = inventorySurfaceConfigs[activeSurface];
  const vaultCollection = vaultCollectionForSurface(status.vault, activeSurface);
  const staticSurfaces: Partial<Record<SurfaceId, ReactNode>> = {
    overview: <OverviewSurface status={status} />,
    vault: <VaultSurface status={status} />,
    routines: <PlannedSurface label={text.routines} detail={text.routineDetail} />,
    devices: <PlannedSurface label={text.devices} detail={text.devicesIntro} />,
    vpnsProxies: <PlannedSurface label={text.vpnsProxies} detail={text.vpnsProxiesIntro} />,
    emailAccounts: <PlannedSurface label={text.emailAccounts} detail={text.managementIntro} />,
    messagingAccounts: <PlannedSurface label={text.messagingAccounts} detail={text.managementIntro} />,
    tasks: <PlannedSurface label={text.tasks} detail={text.managementIntro} />,
    contacts: <PlannedSurface label={text.contacts} detail={text.managementIntro} />,
    events: <PlannedSurface label={text.events} detail={text.managementIntro} />,
    notes: <PlannedSurface label={text.notes} detail={text.managementIntro} />,
    bookmarks: <PlannedSurface label={text.bookmarks} detail={text.managementIntro} />,
    websites: <PlannedSurface label={text.websites} detail={text.websitesIntro} />,
    forums: <PlannedSurface label={text.forums} detail={text.forumsIntro} />,
    socialMedia: <PlannedSurface label={text.socialMedia} detail={text.socialMediaIntro} />,
    marketplaces: <PlannedSurface label={text.marketplaces} detail={text.marketplacesIntro} />,
    inbox: <PlannedSurface label={text.inbox} detail={text.projectWorkIntro} />,
    campaigns: <PlannedSurface label={text.campaigns} detail={text.projectWorkIntro} />,
    cases: <PlannedSurface label={text.cases} detail={text.projectWorkIntro} />,
    projectConfig: <PlannedSurface label={text.config} detail={text.projectWorkIntro} />,
    feedback: <PlannedSurface label={text.feedback} detail={text.projectWorkIntro} />,
    knowledge: <PlannedSurface label={text.knowledge} detail={text.projectWorkIntro} />,
    maintenance: <PlannedSurface label={text.maintenance} detail={text.projectWorkIntro} />,
    performance: <PlannedSurface label={text.performance} detail={text.projectWorkIntro} />,
    reports: <PlannedSurface label={text.reports} detail={text.projectWorkIntro} />,
    apps: <AppsSurface />,
    installation: <InstallationSurface />,
    projects: <ProjectsSurface status={status} />,
    security: <SecuritySurface status={status} />,
    aiProviders: <AiProvidersSurface status={status} />,
  };

  if (isVaultSurfaceLocked(status.vault, activeSurface) && vaultCollection) {
    return <LockedVaultGate collection={vaultCollection} label={activeItem.label} vault={status.vault} />;
  }

  if (activeSurface === "git") {
    return <LocalReposSurface status={status} />;
  }

  if (fileRoot) {
    return <FileExplorerSurface key={fileRoot} rootId={fileRoot} />;
  }

  if (inventoryConfig) {
    return <EditableInventorySurface {...inventoryConfig} />;
  }

  return staticSurfaces[activeSurface] ?? null;
}
