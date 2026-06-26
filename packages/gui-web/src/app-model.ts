import type { GuiFileRootId, GuiStatusData } from "@aidevops/gui-shared";

export type ThemePreference = "system" | "light" | "dark";
export type SidebarMode = "devops" | "comms";
export type FontPreference =
  | "IBM Plex Mono"
  | "IBM Plex Sans"
  | "IBM Plex Serif"
  | "Inter"
  | "Menlo"
  | "Playpen Sans"
  | "Poppins"
  | "Source Sans"
  | "Source Serif"
  | "Tilt Neon"
  | "Ubuntu Mono";
export type FontSizePreference = "xs" | "s" | "m" | "lg" | "xl";
export const surfaceIconNames = {
  apps: true,
  bookmark: true,
  brand: true,
  calendar: true,
  chain: true,
  clock: true,
  device: true,
  document: true,
  download: true,
  folder: true,
  git: true,
  globe: true,
  grid: true,
  hardDrive: true,
  link: true,
  list: true,
  lock: true,
  mail: true,
  message: true,
  note: true,
  package: true,
  server: true,
  settings: true,
  shield: true,
  terminal: true,
  users: true,
} as const;
export type SurfaceIconName = keyof typeof surfaceIconNames;
export const surfaceIds = [
  "overview",
  "vault",
  "agents",
  "config",
  "localSetup",
  "git",
  "routines",
  "devices",
  "vpnsProxies",
  "apps",
  "installation",
  "registrars",
  "hosts",
  "servers",
  "brands",
  "domains",
  "personas",
  "websites",
  "forums",
  "socialMedia",
  "marketplaces",
  "projects",
  "security",
  "aiProviders",
  "emailAccounts",
  "messagingAccounts",
  "tasks",
  "contacts",
  "events",
  "notes",
  "bookmarks",
  "inbox",
  "campaigns",
  "cases",
  "projectConfig",
  "feedback",
  "knowledge",
  "maintenance",
  "performance",
  "reports",
] as const;

export type SurfaceId = (typeof surfaceIds)[number];

export interface SurfaceNavItem {
  badge?: string;
  description: string;
  icon: SurfaceIconName;
  id: SurfaceId;
  label: string;
}

export interface SurfaceNavGroup {
  items: SurfaceNavItem[];
  label: string;
  mode: SidebarMode;
}

export interface FontOption {
  fontFamily: string;
  label: string;
  value: FontPreference;
}

export interface FontSizeOption {
  label: FontSizePreference;
  value: FontSizePreference;
  cssSize: string;
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

export type SurfaceRecordCounts = Partial<Record<SurfaceId, number>>;

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
  bookmarks: "Bookmarks",
  calendars: "Calendars",
  campaigns: "Campaigns",
  cases: "Cases",
  contacts: "Addressbooks",
  development: "Development",
  devops: "DevOps",
  devices: "Devices",
  devicesIntro: "Device inventory and pairing controls are planned for local and remote aidevops installations.",
  emailAccounts: "Email Accounts",
  events: "Events",
  feedback: "Feedback",
  forums: "Forums",
  forumsIntro: "Forum profiles, communities, moderation notes, and owned discussion homes are planned.",
  infrastructure: "Infrastructure",
  identities: "Identities",
  inbox: "Inbox",
  knowledge: "Knowledge",
  latest: "Latest",
  localSetup: "Local Setup",
  localSetupIntro: "Read-only file explorer for ~/.aidevops runtime folders, cache, memory, and deployed assets.",
  localRepos: "Local Repos",
  localReposSetupIntro: "Canonical local repo folders only. Linked worktrees are excluded; controls are read-only until audited write routes land.",
  aiApps: "AI Apps",
  aiAppsIntro: "Local AI app, CLI, config, and aidevops prompt targets. Versions are read-only and compare installed aidevops files with the current checkout.",
  aiProviders: "AI Providers",
  aiProvidersIntro: "OAuth pool account metadata by provider. Tokens stay hidden; Provider AI means task data leaves this device unless Vault policy routes it to Local AI or Hybrid mode.",
  madeForCreators: "Made for creators",
  maintenance: "Maintenance",
  management: "Management",
  managementIntro: "Email accounts, messaging accounts, calendars, addressbooks, tasks, notebooks, and bookmarks will sync through account setup. macOS can use Internet Accounts where available; Linux and Windows need equivalent account providers.",
  markdownFormatted: "Markdown formatted",
  markdownView: "Markdown",
  name: "Name",
  messagingAccounts: "Messaging Accounts",
  marketplaces: "Marketplaces",
  marketplacesIntro: "Marketplace storefronts, seller accounts, product listings, and reputation profiles are planned.",
  noProjectEntries: "No project registry entries are available yet.",
  noPreview: "Select a file to preview safe content.",
  notes: "Notebooks",
  operations: "Operations",
  parentDirectory: "..",
  path: "Path",
  personas: "Personas",
  personasIntro: "Draft identity list for first and last names.",
  planned: "planned",
  plannedHomes: "Planned homes",
  plannedNotice: "This surface is a local UI placeholder. Persistence and actions need explicit trust-boundary work.",
  comms: "Comms",
  performance: "Performance",
  projectWorkIntro: "Document folders for inboxes, campaigns, cases, configuration, feedback, knowledge, maintenance, performance, and reports are planned.",
  projectWork: "Documents",
  projects: "Remote Repos",
  readOnly: "Read-only",
  registrars: "Registrars",
  registrarsIntro: "Recommended and user-owned domain registrars.",
  repoDescription: "AI-assisted development workflows, code quality, and deployment automation.",
  reports: "Reports",
  roadmapIntro: "Made for creators",
  routines: "Routines",
  routineDetail: "Routine schedule, next run, run history, script/LLM-backed type, and diagnostic homes are planned.",
  searchPlaceholder: "Search setup, files, providers",
  secrets: "Secrets",
  security: "Secrets",
  securityBoundary: "No write routes, no shell bridge, no hosted app control, no pairing, no secret values. Vault policy distinguishes Provider AI, Local AI, and Hybrid modes before protected data leaves the device.",
  servers: "Servers",
  serversIntro: "Server inventory by provider, operating system, orchestrator, and installed apps.",
  setup: "Setup",
  setupTargets: "Installed aidevops targets",
  setupTargetsIntro: "Files and settings paths that setup/update deploys into local runtimes. Missing or older targets need setup/update before release.",
  sites: "Sites",
  socialMedia: "Social Media",
  socialMediaIntro: "Social profiles, pages, handles, audience notes, and channel ownership are planned.",
  tasks: "Tasks",
  theme: "Theme",
  appearance: "Appearance",
  hue: "Hue",
  reset: "Reset",
  showBorders: "Show borders",
  showCounts: "Show counts",
  font: "Font",
  fontSize: "Font size",
  truncated: "Preview truncated for safety.",
  update: "Update",
  vault: "Vault",
  vaultAudit: "Audit Logs",
  vaultBackups: "Backups & Recovery",
  vaultCollectionIntro: "Encrypted collections are metadata-only while locked. Protected previews and write actions stay disabled until a local unlock succeeds.",
  vaultDevices: "Devices",
  vaultIntro: "Local encrypted metadata, lock/unlock readiness, device trust, encrypted sync, secure messages, backups, and audit placeholders.",
  vaultLockedPreview: "Vault locked: protected previews are hidden and write actions are disabled.",
  vaultLockUnlock: "Lock / Unlock",
  vaultMessages: "Secure Messages",
  vaultSetup: "First-use Setup",
  vaultStatus: "Status",
  vaultSync: "Sync",
  vaultTooltip: "Encrypted by aidevops Vault; contents visible only when unlocked through app or authorised vault commands.",
  vaultUnlockCta: "Unlock Vault",
  vaultUnlockHint: "Run `aidevops vault unlock` in a local terminal and enter the passphrase only into the hidden prompt.",
  website: "Website",
  websites: "Websites",
  websitesIntro: "Websites, landing pages, publishing homes, and ownership status are planned.",
  workspaceLabel: "aidevops workspace",
  vpnsProxies: "VPNs & Proxies",
  vpnsProxiesIntro: "VPN and proxy inventory is planned for network-aware device management.",
  navigationLabel: "aidevops navigation",
} as const;

export const DEFAULT_ACCENT_HUE = 123;
export const DEFAULT_FONT: FontPreference = "Menlo";
export const DEFAULT_FONT_SIZE: FontSizePreference = "m";

export const fontOptions: FontOption[] = [
  { value: "IBM Plex Mono", label: "IBM Plex Mono", fontFamily: '"IBM Plex Mono", Menlo, Monaco, Consolas, monospace' },
  { value: "IBM Plex Sans", label: "IBM Plex Sans", fontFamily: '"IBM Plex Sans", Inter, system-ui, sans-serif' },
  { value: "IBM Plex Serif", label: "IBM Plex Serif", fontFamily: '"IBM Plex Serif", Georgia, serif' },
  { value: "Inter", label: "Inter", fontFamily: 'Inter, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif' },
  { value: "Menlo", label: "Menlo (default)", fontFamily: 'Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace' },
  { value: "Playpen Sans", label: "Playpen Sans", fontFamily: '"Playpen Sans", "Comic Sans MS", Inter, system-ui, sans-serif' },
  { value: "Poppins", label: "Poppins", fontFamily: 'Poppins, Inter, system-ui, sans-serif' },
  { value: "Source Sans", label: "Source Sans", fontFamily: '"Source Sans 3", "Source Sans Pro", "Source Sans", Inter, system-ui, sans-serif' },
  { value: "Source Serif", label: "Source Serif", fontFamily: '"Source Serif 4", "Source Serif Pro", "Source Serif", Georgia, serif' },
  { value: "Tilt Neon", label: "Tilt Neon", fontFamily: '"Tilt Neon", Poppins, Inter, system-ui, sans-serif' },
  { value: "Ubuntu Mono", label: "Ubuntu Mono", fontFamily: '"Ubuntu Mono", Menlo, Monaco, Consolas, monospace' },
];

export const fontSizeOptions: FontSizeOption[] = (["xs", "s", "m", "lg", "xl"] as const).map((size, index) => ({
  value: size,
  label: size,
  cssSize: `${14 + index}px`,
}));

export const navGroups: SurfaceNavGroup[] = [
  {
    label: text.development,
    mode: "devops",
    items: [
      { id: "git", label: text.localRepos, description: "~/Git explorer", icon: "folder" },
      { id: "projects", label: text.projects, description: "repos.json summary", icon: "git" },
      { id: "security", label: text.secrets, description: "Secret references and trust boundary", icon: "shield" },
      { id: "aiProviders", label: text.aiProviders, description: "OAuth account pools", icon: "users" },
    ],
  },
  {
    label: text.operations,
    mode: "devops",
    items: [
      { id: "vault", label: text.vault, description: "Encrypted metadata, setup, sync, and audit", icon: "lock" },
      { id: "agents", label: "Agents", description: "~/.aidevops/agents explorer", icon: "document" },
      { id: "config", label: text.config, description: "~/.config/aidevops explorer", icon: "settings" },
      { id: "localSetup", label: text.localSetup, description: "~/.aidevops explorer", icon: "terminal" },
      { id: "routines", label: text.routines, description: "Scheduled workflows", icon: "clock", badge: text.planned },
    ],
  },
  {
    label: text.infrastructure,
    mode: "devops",
    items: [
      { id: "devices", label: text.devices, description: "Installed aidevops machines", icon: "device", badge: text.planned },
      { id: "vpnsProxies", label: text.vpnsProxies, description: "VPN and proxy inventory", icon: "shield", badge: text.planned },
      { id: "apps", label: text.apps, description: "Installed tools and apps", icon: "package" },
      { id: "installation", label: text.installation, description: "Optional setup toggles", icon: "download" },
      { id: "registrars", label: text.registrars, description: "Domain registrars", icon: "chain" },
      { id: "hosts", label: text.hosts, description: "Hosting providers", icon: "server" },
      { id: "servers", label: text.servers, description: "Servers and orchestrators", icon: "hardDrive" },
    ],
  },
  {
    label: text.identities,
    mode: "comms",
    items: [
      { id: "brands", label: text.brands, description: "Brands and websites", icon: "brand" },
      { id: "domains", label: text.domains, description: "Owned domains", icon: "globe" },
      { id: "personas", label: text.personas, description: "People and identities", icon: "users" },
    ],
  },
  {
    label: text.sites,
    mode: "comms",
    items: [
      { id: "websites", label: text.websites, description: "Owned websites and landing pages", icon: "globe", badge: text.planned },
      { id: "forums", label: text.forums, description: "Forums and communities", icon: "message", badge: text.planned },
      { id: "socialMedia", label: text.socialMedia, description: "Social channels and handles", icon: "users", badge: text.planned },
      { id: "marketplaces", label: text.marketplaces, description: "Storefronts and seller profiles", icon: "package", badge: text.planned },
    ],
  },
  {
    label: text.management,
    mode: "comms",
    items: [
      { id: "emailAccounts", label: text.emailAccounts, description: "Mail account sync", icon: "mail", badge: text.planned },
      { id: "messagingAccounts", label: text.messagingAccounts, description: "Messaging account sync", icon: "message", badge: text.planned },
      { id: "events", label: text.calendars, description: "CalDAV calendar sync", icon: "calendar", badge: text.planned },
      { id: "contacts", label: text.contacts, description: "CardDAV contact sync", icon: "users", badge: text.planned },
      { id: "tasks", label: text.tasks, description: "CalDAV task sync", icon: "list", badge: text.planned },
      { id: "notes", label: text.notes, description: "Synced notes", icon: "note", badge: text.planned },
      { id: "bookmarks", label: text.bookmarks, description: "Saved links and references", icon: "bookmark", badge: text.planned },
    ],
  },
  {
    label: text.projectWork,
    mode: "comms",
    items: [
      { id: "inbox", label: text.inbox, description: "Project intake", icon: "folder", badge: text.planned },
      { id: "campaigns", label: text.campaigns, description: "Campaign folders", icon: "folder", badge: text.planned },
      { id: "cases", label: text.cases, description: "Case folders", icon: "folder", badge: text.planned },
      { id: "projectConfig", label: text.config, description: "Project configuration", icon: "folder", badge: text.planned },
      { id: "feedback", label: text.feedback, description: "Feedback folders", icon: "folder", badge: text.planned },
      { id: "knowledge", label: text.knowledge, description: "Knowledge folders", icon: "folder", badge: text.planned },
      { id: "maintenance", label: text.maintenance, description: "Maintenance folders", icon: "folder", badge: text.planned },
      { id: "performance", label: text.performance, description: "Performance folders", icon: "folder", badge: text.planned },
      { id: "reports", label: text.reports, description: "Report folders", icon: "folder", badge: text.planned },
    ],
  },
];

export const dashboardNavItem: SurfaceNavItem = {
  id: "overview",
  label: text.dashboard,
  description: "Setup, status, and roadmap homes",
  icon: "grid",
};

export const orderedNavItems: SurfaceNavItem[] = [
  dashboardNavItem,
  ...navGroups.flatMap((group) => group.items),
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
  { area: "Vault", home: "Vault status, setup, devices, sync, messages, backups, audit", phase: "P6/Vault" },
  { area: "Local and remote repos", home: "Local Repos + Remote Repos", phase: "P7" },
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

export function fontFamilyForPreference(font: FontPreference): string {
  return fontOptions.find((option) => option.value === font)?.fontFamily ?? fontOptions.find((option) => option.value === DEFAULT_FONT)?.fontFamily ?? "Menlo, monospace";
}

export function fontSizeForPreference(size: FontSizePreference): string {
  return fontSizeOptions.find((option) => option.value === size)?.cssSize ?? fontSizeOptions.find((option) => option.value === DEFAULT_FONT_SIZE)?.cssSize ?? "16px";
}

export function isFontPreference(value: string | null): value is FontPreference {
  return fontOptions.some((option) => option.value === value);
}

export function isFontSizePreference(value: string | null): value is FontSizePreference {
  return fontSizeOptions.some((option) => option.value === value);
}

export function sidebarModeForSurface(id: SurfaceId): SidebarMode {
  return navGroups.find((group) => group.items.some((item) => item.id === id))?.mode ?? "devops";
}

export function findSurface(id: SurfaceId): SurfaceNavItem {
  return orderedNavItems.find((item) => item.id === id) ?? dashboardNavItem;
}

export function findSurfaceSectionLabel(id: SurfaceId): string {
  if (id === dashboardNavItem.id) {
    return text.aidevops;
  }

  for (const group of navGroups) {
    for (const item of group.items) {
      if (item.id === id) {
        return group.label;
      }
    }
  }

  return text.aidevops;
}

export function surfaceRecordCounts(status: GuiStatusData): SurfaceRecordCounts {
  const oauthAccounts = status.oauth_pool.providers.reduce((total, provider) => total + provider.total, 0);

  return {
    agents: status.capabilities.length,
    aiProviders: oauthAccounts,
    apps: appRows.length,
    config: status.settings.key_count || status.settings.keys.length,
    git: status.local_repos.total || status.local_repos.repos.length,
    hosts: populatedInventoryRowCount("hosts"),
    installation: installationRows.length,
    localSetup: status.paths.length,
    projects: status.repos.total || status.repos.repos.length,
    registrars: populatedInventoryRowCount("registrars"),
    security: status.secrets.length,
    servers: populatedInventoryRowCount("servers"),
    vault: status.vault.collections.length,
  };
}

function populatedInventoryRowCount(surface: SurfaceId): number {
  return inventorySurfaceConfigs[surface]?.initialRows.filter((row) => Object.values(row).some((value) => value.trim().length > 0)).length ?? 0;
}
