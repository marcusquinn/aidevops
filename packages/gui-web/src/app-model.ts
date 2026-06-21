import type { GuiFileRootId } from "@aidevops/gui-shared";

export type ThemePreference = "system" | "light" | "dark";
export const surfaceIds = [
  "overview",
  "agents",
  "config",
  "localSetup",
  "git",
  "routines",
  "apps",
  "installation",
  "personas",
  "brands",
  "domains",
  "registrars",
  "hosts",
  "servers",
  "projects",
  "security",
] as const;

export type SurfaceId = (typeof surfaceIds)[number];

export interface SurfaceNavItem {
  badge?: string;
  description: string;
  icon: string;
  id: SurfaceId;
  label: string;
}

export interface SurfaceNavGroup {
  items: SurfaceNavItem[];
  label: string;
}

export interface InventoryColumn {
  key: string;
  label: string;
}

export interface InventorySurfaceConfig {
  columns: InventoryColumn[];
  initialRows: Record<string, string>[];
  intro: string;
  title: string;
}

export const text = {
  aidevops: "aidevops",
  appShell: "App shell",
  apps: "Apps",
  appsIntro: "App and CLI inventory for tools installed or updated by aidevops. Version and homepage adapters are planned.",
  appStatusPending: "adapter pending",
  brands: "Brands",
  brandsIntro: "Draft brand inventory for names and website references.",
  codeView: "Code",
  config: "Config",
  configIntro: "Read-only file explorer for ~/.config/aidevops. Contents stay hidden until redaction rules land.",
  copyPath: "Copy path",
  dashboard: "Dashboard",
  domains: "Domains",
  domainsIntro: "Draft domain ownership inventory across providers.",
  draftOnly: "Local browser draft only. Saving requires a write-action manifest, confirmation, and audit trail.",
  fileBrowser: "File browser",
  folderOpenBlocked: "Native folder opening needs a desktop bridge and an allowlisted action.",
  git: "Git",
  gitIntro: "Read-only file explorer for ~/Git workspaces and worktrees.",
  hosts: "Hosts",
  hostsIntro: "Recommended and user-owned hosting providers with setup notes later.",
  addRow: "Add row",
  channel: "Channel",
  installation: "Installation",
  installationIntro: "Optional aidevops setup/update components. Toggles are shown as planned controls until writes are enabled.",
  install: "Install",
  inventory: "Inventory",
  latest: "Latest",
  localSetup: "Local Setup",
  localSetupIntro: "Read-only file explorer for ~/.aidevops runtime folders, cache, memory, and deployed assets.",
  markdownFormatted: "Markdown formatted",
  markdownView: "Markdown",
  name: "Name",
  noProjectEntries: "No project registry entries are available yet.",
  noPreview: "Select a file to preview safe content.",
  operations: "Operations",
  parentDirectory: "..",
  path: "Path",
  personas: "Personas",
  personasIntro: "Draft identity list for first and last names.",
  planned: "planned",
  plannedHomes: "Planned homes",
  plannedNotice: "This surface is a local UI placeholder. Persistence and actions need explicit trust-boundary work.",
  projects: "Projects",
  readOnly: "Read-only",
  registrars: "Registrars",
  registrarsIntro: "Recommended and user-owned domain registrars.",
  roadmapIntro: "The GUI plan already has homes for setup/status, Git/repos, infrastructure inventory, providers, routines, agents, Cloudron, pairing, OpenCode sessions, and desktop packaging.",
  routines: "Routines",
  routineDetail: "Routine schedule, next run, run history, script/LLM-backed type, and diagnostic homes are planned.",
  searchPlaceholder: "Search setup, files, providers",
  security: "Security",
  securityBoundary: "No write routes, no shell bridge, no hosted app control, no pairing, no secret values.",
  servers: "Servers",
  serversIntro: "Server inventory by provider, operating system, orchestrator, and installed apps.",
  setup: "Setup",
  theme: "Theme",
  truncated: "Preview truncated for safety.",
  update: "Update",
  website: "Website",
  workspaceLabel: "aidevops workspace",
  navigationLabel: "aidevops navigation",
} as const;

export const navGroups: SurfaceNavGroup[] = [
  {
    label: text.operations,
    items: [
      { id: "overview", label: text.dashboard, description: "Setup, status, and roadmap homes", icon: "⌘" },
      { id: "agents", label: "Agents", description: "~/.aidevops/agents explorer", icon: "A" },
      { id: "config", label: text.config, description: "~/.config/aidevops explorer", icon: "C" },
      { id: "localSetup", label: text.localSetup, description: "~/.aidevops explorer", icon: "L" },
      { id: "git", label: text.git, description: "~/Git explorer", icon: "G" },
      { id: "routines", label: text.routines, description: "Scheduled workflows", icon: "R", badge: text.planned },
    ],
  },
  {
    label: text.inventory,
    items: [
      { id: "apps", label: text.apps, description: "Installed tools and apps", icon: "P" },
      { id: "installation", label: text.installation, description: "Optional setup toggles", icon: "I" },
      { id: "personas", label: text.personas, description: "People and identities", icon: "P" },
      { id: "brands", label: text.brands, description: "Brands and websites", icon: "B" },
      { id: "domains", label: text.domains, description: "Owned domains", icon: "D" },
      { id: "registrars", label: text.registrars, description: "Domain registrars", icon: "R" },
      { id: "hosts", label: text.hosts, description: "Hosting providers", icon: "H" },
      { id: "servers", label: text.servers, description: "Servers and orchestrators", icon: "S" },
    ],
  },
  {
    label: "Reference",
    items: [
      { id: "projects", label: text.projects, description: "repos.json summary", icon: "◇" },
      { id: "security", label: text.security, description: "Trust boundary", icon: "◈" },
    ],
  },
];

export const fileRootBySurface: Partial<Record<SurfaceId, GuiFileRootId>> = {
  agents: "agents",
  config: "config",
  localSetup: "localSetup",
  git: "git",
};

export const appRows = [
  { name: "aidevops", latest: text.appStatusPending, channel: "setup/update", website: "https://aidevops.sh" },
  { name: "OpenCode", latest: text.appStatusPending, channel: "runtime", website: text.appStatusPending },
  { name: "Bun", latest: text.appStatusPending, channel: "toolchain", website: text.appStatusPending },
  { name: "GitHub CLI", latest: text.appStatusPending, channel: "git", website: text.appStatusPending },
  { name: "ShellCheck", latest: text.appStatusPending, channel: "quality", website: text.appStatusPending },
  { name: "Biome", latest: text.appStatusPending, channel: "quality", website: text.appStatusPending },
];

export const installationRows = [
  { name: "OpenCode runtime", install: true, update: true, scope: "core" },
  { name: "GUI desktop launcher", install: true, update: true, scope: "local" },
  { name: "Shell quality tools", install: true, update: true, scope: "quality" },
  { name: "Cloudron helpers", install: false, update: false, scope: "optional" },
  { name: "Calendar sync helpers", install: false, update: false, scope: "optional" },
];

export const plannedHomes = [
  { area: "Setup/status", home: "Dashboard + Local Setup", phase: "P6" },
  { area: "Repos and local Git", home: "Projects + Git", phase: "P7" },
  { area: "Infrastructure inventory", home: "Domains, Registrars, Hosts, Servers", phase: "P8" },
  { area: "Provider catalog", home: "Registrars, Hosts, Apps", phase: "P9" },
  { area: "Routines", home: "Routines", phase: "P10" },
  { area: "Agents and knowledgebase", home: "Agents", phase: "P12" },
  { area: "Cloudron and machine pairing", home: "Servers + Apps", phase: "P13/P14" },
  { area: "OpenCode sessions", home: "Future Sessions surface", phase: "P15" },
  { area: "Desktop wrapper", home: "Installation", phase: "P16" },
];

export const inventorySurfaceConfigs: Partial<Record<SurfaceId, InventorySurfaceConfig>> = {
  personas: {
    title: text.personas,
    intro: text.personasIntro,
    columns: [
      { key: "firstName", label: "First Name" },
      { key: "lastName", label: "Last Name" },
    ],
    initialRows: [{ firstName: "", lastName: "" }],
  },
  brands: {
    title: text.brands,
    intro: text.brandsIntro,
    columns: [
      { key: "brandName", label: "Brand Name" },
      { key: "website", label: "Website URL" },
    ],
    initialRows: [{ brandName: "", website: "" }],
  },
  domains: {
    title: text.domains,
    intro: text.domainsIntro,
    columns: [
      { key: "domain", label: "Domain" },
      { key: "provider", label: "Provider" },
      { key: "status", label: "Status" },
    ],
    initialRows: [{ domain: "", provider: "", status: "" }],
  },
  registrars: {
    title: text.registrars,
    intro: text.registrarsIntro,
    columns: [
      { key: "name", label: "Registrar" },
      { key: "recommendation", label: "Recommendation" },
      { key: "notes", label: "Notes" },
    ],
    initialRows: [
      { name: "Porkbun", recommendation: "recommended", notes: "provider catalog" },
      { name: "Cloudflare Registrar", recommendation: "recommended", notes: "provider catalog" },
    ],
  },
  hosts: {
    title: text.hosts,
    intro: text.hostsIntro,
    columns: [
      { key: "name", label: "Host" },
      { key: "category", label: "Category" },
      { key: "notes", label: "Notes" },
    ],
    initialRows: [
      { name: "Cloudron", category: "app platform", notes: "recommended" },
      { name: "Coolify", category: "app platform", notes: "recommended" },
      { name: "Ubicloud", category: "cloud", notes: "recommended" },
    ],
  },
  servers: {
    title: text.servers,
    intro: text.serversIntro,
    columns: [
      { key: "provider", label: "Provider" },
      { key: "server", label: "Server" },
      { key: "os", label: "OS" },
      { key: "orchestrator", label: "Orchestrator" },
      { key: "apps", label: "Apps" },
    ],
    initialRows: [{ provider: "", server: "", os: "", orchestrator: "", apps: "" }],
  },
};

export function getSystemTheme(): "light" | "dark" {
  if (typeof window === "undefined") {
    return "light";
  }

  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function findSurface(id: SurfaceId): SurfaceNavItem {
  for (const group of navGroups) {
    for (const item of group.items) {
      if (item.id === id) {
        return item;
      }
    }
  }

  return navGroups[0].items[0];
}
