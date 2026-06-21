/* jshint esversion: 11 */
import { navGroups, text } from "./app-model";
import type { SurfaceId, SurfaceNavGroup, SurfaceNavItem, ThemePreference } from "./app-model";

export function Sidebar({ activeSurface, setActiveSurface, setThemePreference, themePreference }: {
  activeSurface: SurfaceId;
  setActiveSurface: (surface: SurfaceId) => void;
  setThemePreference: (theme: ThemePreference) => void;
  themePreference: ThemePreference;
}) {
  return (
    <aside className="app-sidebar" aria-label={text.navigationLabel}>
      <SidebarHeader />
      <nav className="sidebar-content">
        {navGroups.map((group) => <SidebarGroup activeSurface={activeSurface} group={group} key={group.label} setActiveSurface={setActiveSurface} />)}
      </nav>
      <SidebarFooter setThemePreference={setThemePreference} themePreference={themePreference} />
    </aside>
  );
}

function SidebarGroup({ activeSurface, group, setActiveSurface }: {
  activeSurface: SurfaceId;
  group: SurfaceNavGroup;
  setActiveSurface: (surface: SurfaceId) => void;
}) {
  return (
    <section className="sidebar-group">
      <h2>{group.label}</h2>
      <ul>
        {group.items.map((item) => <SidebarItem activeSurface={activeSurface} item={item} key={item.id} setActiveSurface={setActiveSurface} />)}
      </ul>
    </section>
  );
}

function SidebarItem({ activeSurface, item, setActiveSurface }: {
  activeSurface: SurfaceId;
  item: SurfaceNavItem;
  setActiveSurface: (surface: SurfaceId) => void;
}) {
  const isActive = activeSurface === item.id;

  return (
    <li>
      <button
        aria-current={isActive ? "page" : undefined}
        className={isActive ? "surface-link active" : "surface-link"}
        onClick={() => setActiveSurface(item.id)}
        type="button"
      >
        <span className="surface-icon" aria-hidden="true">{item.icon}</span>
        <span className="surface-copy">
          <strong>{item.label}</strong>
          <small>{item.description}</small>
        </span>
        {item.badge ? <em>{item.badge}</em> : null}
      </button>
    </li>
  );
}

function SidebarHeader() {
  return (
    <header className="sidebar-header">
      <div className="brand-lockup">
        <span className="terminal-mark" aria-hidden="true">›_</span>
        <strong>{text.aidevops}</strong>
      </div>
    </header>
  );
}

function SidebarFooter({ setThemePreference, themePreference }: {
  setThemePreference: (theme: ThemePreference) => void;
  themePreference: ThemePreference;
}) {
  return (
    <footer className="sidebar-footer">
      <p>{text.theme}</p>
      <div className="theme-control compact">
        {(["system", "light", "dark"] as const).map((theme) => (
          <button
            aria-pressed={themePreference === theme}
            className={themePreference === theme ? "theme-option active" : "theme-option"}
            key={theme}
            onClick={() => setThemePreference(theme)}
            type="button"
          >
            {theme}
          </button>
        ))}
      </div>
    </footer>
  );
}
