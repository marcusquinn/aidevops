/* jshint esversion: 11 */
import type { GuiFileRootId, GuiStatusData } from "../../gui-shared/src";
import { inventorySurfaceConfigs, text } from "./app-model";
import type { SurfaceId, SurfaceNavItem } from "./app-model";
import { FileExplorerSurface } from "./FileExplorerSurface";
import { AppsSurface, EditableInventorySurface, InstallationSurface } from "./InventorySurfaces";
import { OverviewSurface, PlannedSurface, ProjectsSurface, SecuritySurface } from "./StatusSurfaces";

export function Workspace({ activeItem, activeSurface, fileRoot, status }: {
  activeItem: SurfaceNavItem;
  activeSurface: SurfaceId;
  fileRoot: GuiFileRootId | undefined;
  status: GuiStatusData;
}) {
  return (
    <section className="app-inset" aria-label={text.workspaceLabel}>
      <WorkspaceHeader activeItem={activeItem} />
      <div className="workspace-scroll">
        <SurfaceContent activeSurface={activeSurface} fileRoot={fileRoot} status={status} />
      </div>
    </section>
  );
}

function WorkspaceHeader({ activeItem }: { activeItem: SurfaceNavItem }) {
  return (
    <header className="workspace-header">
      <div className="header-title">
        <button className="sidebar-trigger" type="button" aria-label="Sidebar is fixed in this preview">☰</button>
        <div>
          <p>{text.appShell}</p>
          <h1>{activeItem.label}</h1>
        </div>
      </div>
      <div className="header-actions">
        <label className="workspace-search">
          <span>⌘K</span>
          <input disabled placeholder={text.searchPlaceholder} />
        </label>
        <span className="read-only-pill"><i />{text.readOnly}</span>
      </div>
    </header>
  );
}

function SurfaceContent({ activeSurface, fileRoot, status }: {
  activeSurface: SurfaceId;
  fileRoot: GuiFileRootId | undefined;
  status: GuiStatusData;
}) {
  const inventoryConfig = inventorySurfaceConfigs[activeSurface];

  if (fileRoot) {
    return <FileExplorerSurface key={fileRoot} rootId={fileRoot} />;
  }

  if (inventoryConfig) {
    return <EditableInventorySurface {...inventoryConfig} />;
  }

  switch (activeSurface) {
    case "overview":
      return <OverviewSurface status={status} />;
    case "routines":
      return <PlannedSurface label={text.routines} detail={text.routineDetail} />;
    case "apps":
      return <AppsSurface />;
    case "installation":
      return <InstallationSurface />;
    case "projects":
      return <ProjectsSurface status={status} />;
    case "security":
      return <SecuritySurface status={status} />;
    default:
      return null;
  }
}
