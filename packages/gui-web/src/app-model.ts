import type { GuiFileRootId, GuiStatusData } from "@aidevops/gui-shared";

export type ThemePreference = "system" | "light" | "dark";
export type SidebarMode = "devops" | "comms";
export type ShellMode = "devices" | "sessions";
export type ConversationMode = "ai" | "people";
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
  hash: true,
  help: true,
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
  "help",
  "settings",
  "notifications",
  "admin",
  "vault",
  "agents",
  "config",
  "localSetup",
  "git",
  "aiSessions",
  "channels",
  "directMessages",
  "workers",
  "repos",
  "deployments",
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
  appsIntro: "These are the apps we use and recommend from our tried & tested toolkit — enabling all the things we can do with AI, development, and operations to create and share our work. Opinionated preferences based on open-source-first, lowest-costs, highest-quality UI & UX, teamwork, data security, privacy, and AI-usage capabilities.",
  appStatusPending: "adapter pending",
  brands: "Brands",
  brandsIntro: "Draft brand inventory for names and website references.",
  codeView: "Code",
  config: "Config",
  configIntro: "Read-only file explorer for ~/.config/aidevops. Contents stay hidden until redaction rules land.",
  copyPath: "Copy path",
  dashboard: "Dashboard",
  help: "Help",
  helpIntro: "Command shortcuts, navigation hints, and aidevops workflow guidance will collect here.",
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
  channels: "Channels",
  channelsIntro: "Team channels use the unified conversation model. Message payloads stay read-only placeholders until encrypted transport and audited write routes land.",
  deployments: "Deployments",
  deploymentsIntro: "Deployment activity, environments, releases, and rollout checks will collect here after repo/deploy adapters land.",
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
  ai: "AI",
  people: "People",
  newSession: "New Session",
  sessionHistory: "Session history",
  opencodeSessions: "OpenCode sessions",
  aiSessions: "AI Sessions",
  aiSessionsIntro: "AI sessions bridge OpenCode metadata today and will adopt Turbostarter AI persistence, transport, attachments, tools, and history behind audited routes.",
  simplexReady: "SimpleX transport placeholder: encrypted channel adapters will mount here behind Vault and trust-boundary checks.",
  teams: "Teams",
  directMessages: "Direct Messages",
  directMessagesIntro: "Direct and group DM threads share the unified conversation model while protected payloads remain gated by Vault policy.",
  chatInputPlaceholder: "Write a message when audited session write routes are enabled.",
  localRepoSelector: "Local repo selector",
  performance: "Performance",
  projectWorkIntro: "Document folders for inboxes, campaigns, cases, configuration, feedback, knowledge, maintenance, performance, and reports are planned.",
  projectWork: "Documents",
  projects: "Remote Repos",
  repos: "Repos",
  reposIntro: "Unified repo context for local worktrees, remote repo metadata, worker threads, and future deploy context.",
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
  settingsAccountIntro: "Hosted account settings are prepared as disabled controls until authenticated write routes, confirmation, and audit trails land.",
  servers: "Servers",
  serversIntro: "Server inventory by provider, operating system, orchestrator, and installed apps.",
  setup: "Setup",
  setupTargets: "Installed aidevops targets",
  setupTargetsIntro: "Files and settings paths that setup/update deploys into local runtimes. Missing or older targets need setup/update before release.",
  sites: "Sites",
  socialMedia: "Social Media",
  socialMediaIntro: "Social profiles, pages, handles, audience notes, and channel ownership are planned.",
  tasks: "Tasks",
  workers: "Workers",
  workersIntro: "Worker activity, task handoffs, event threads, and status transitions will render here as conversation events and workflow summaries.",
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

function plannedNavItem(id: SurfaceId, label: string, description: string, icon: SurfaceIconName): SurfaceNavItem {
  return { id, label, description, icon, badge: text.planned };
}

function plannedCommsGroup(label: string, items: SurfaceNavItem[]): SurfaceNavGroup {
  return { label, mode: "comms", items };
}

export const navGroups: SurfaceNavGroup[] = [
  {
    label: text.infrastructure,
    mode: "devops",
    items: [
      { id: "devices", label: text.devices, description: "Installed aidevops machines", icon: "device", badge: text.planned },
      { id: "apps", label: text.apps, description: "Installed tools and apps", icon: "package" },
      { id: "vpnsProxies", label: text.vpnsProxies, description: "VPN and proxy inventory", icon: "shield", badge: text.planned },
      { id: "installation", label: text.installation, description: "Optional setup toggles", icon: "download" },
      { id: "registrars", label: text.registrars, description: "Domain registrars", icon: "chain" },
      { id: "hosts", label: text.hosts, description: "Hosting providers", icon: "server" },
      { id: "servers", label: text.servers, description: "Servers and orchestrators", icon: "hardDrive" },
    ],
  },
  {
    label: text.development,
    mode: "devops",
    items: [
      plannedNavItem("aiSessions", text.aiSessions, "AI chat and OpenCode sessions", "terminal"),
      plannedNavItem("workers", text.workers, "Worker activity and event threads", "users"),
      { id: "git", label: text.localRepos, description: "~/Git explorer", icon: "folder" },
      plannedNavItem("repos", text.repos, "Unified local and remote repo context", "git"),
      { id: "projects", label: text.projects, description: "repos.json summary", icon: "git" },
      plannedNavItem("deployments", text.deployments, "Release and deployment activity", "download"),
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
  plannedCommsGroup(text.management, [
    plannedNavItem("channels", text.channels, "Team channels", "hash"),
    plannedNavItem("directMessages", text.directMessages, "Direct and group DMs", "message"),
    plannedNavItem("emailAccounts", text.emailAccounts, "Mail account sync", "mail"),
    plannedNavItem("messagingAccounts", text.messagingAccounts, "Messaging account sync", "message"),
    plannedNavItem("events", text.calendars, "CalDAV calendar sync", "calendar"),
    plannedNavItem("contacts", text.contacts, "CardDAV contact sync", "users"),
    plannedNavItem("tasks", text.tasks, "CalDAV task sync", "list"),
    plannedNavItem("notes", text.notes, "Synced notes", "note"),
    plannedNavItem("bookmarks", text.bookmarks, "Saved links and references", "bookmark"),
  ]),
  plannedCommsGroup(text.projectWork, [
    plannedNavItem("inbox", text.inbox, "Project intake", "folder"),
    plannedNavItem("campaigns", text.campaigns, "Campaign folders", "folder"),
    plannedNavItem("cases", text.cases, "Case folders", "folder"),
    plannedNavItem("projectConfig", text.config, "Project configuration", "folder"),
    plannedNavItem("feedback", text.feedback, "Feedback folders", "folder"),
    plannedNavItem("knowledge", text.knowledge, "Knowledge folders", "folder"),
    plannedNavItem("maintenance", text.maintenance, "Maintenance folders", "folder"),
    plannedNavItem("performance", text.performance, "Performance folders", "folder"),
    plannedNavItem("reports", text.reports, "Report folders", "folder"),
  ]),
];

export const dashboardNavItem: SurfaceNavItem = {
  id: "overview",
  label: text.dashboard,
  description: "Setup, status, and roadmap homes",
  icon: "grid",
};

export const utilityNavItems: SurfaceNavItem[] = [
  { id: "help", label: text.help, description: "Shortcuts, command palette symbols, and support", icon: "help", badge: text.planned },
  { id: "settings", label: "Settings", description: "Profile, login, notifications, language, and theme preferences", icon: "settings", badge: text.planned },
  { id: "notifications", label: "Notifications", description: "Notification inbox and delivery preferences", icon: "message", badge: text.planned },
  { id: "admin", label: "Admin", description: "Hosted administration controls", icon: "shield", badge: text.planned },
];

export const orderedNavItems: SurfaceNavItem[] = [
  dashboardNavItem,
  ...utilityNavItems,
  ...navGroups.flatMap((group) => group.items),
];

export const fileRootBySurface: Partial<Record<SurfaceId, GuiFileRootId>> = {
  agents: "agents",
  config: "config",
  localSetup: "localSetup",
  git: "git",
};

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
  if (utilityNavItems.some((item) => item.id === id)) {
    return "comms";
  }

  return navGroups.find((group) => group.items.some((item) => item.id === id))?.mode ?? "devops";
}

export function findSurface(id: SurfaceId): SurfaceNavItem {
  return orderedNavItems.find((item) => item.id === id) ?? dashboardNavItem;
}

export function findSurfaceSectionLabel(id: SurfaceId): string {
  if (id === dashboardNavItem.id) {
    return text.aidevops;
  }

  if (utilityNavItems.some((item) => item.id === id)) {
    return "Account";
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
    aiSessions: status.opencode_sessions.sessions.length,
    apps: status.managed_apps.length || status.ai_apps.length,
    config: status.settings.key_count || status.settings.keys.length,
    git: status.local_repos.total || status.local_repos.repos.length,
    hosts: populatedInventoryRowCount("hosts"),
    installation: installationRows.length,
    localSetup: status.paths.length,
    notifications: status.notifications.filter((notification) => notification.status === "active").length,
    projects: status.repos.total || status.repos.repos.length,
    repos: (status.local_repos.total || status.local_repos.repos.length) + (status.repos.total || status.repos.repos.length),
    registrars: populatedInventoryRowCount("registrars"),
    security: status.secrets.length,
    servers: populatedInventoryRowCount("servers"),
    vault: status.vault.collections.length,
  };
}

function populatedInventoryRowCount(surface: SurfaceId): number {
  return inventorySurfaceConfigs[surface]?.initialRows.filter((row) => Object.values(row).some((value) => value.trim().length > 0)).length ?? 0;
}
