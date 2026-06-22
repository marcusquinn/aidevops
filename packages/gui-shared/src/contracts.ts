export type GuiRouteClassification = "read" | "write" | "destructive";

export type GuiOperationId = "setup.status.read" | "capabilities.read" | "filesystem.read";

export type GuiFileRootId = "agents" | "config" | "localSetup" | "git";

export interface GuiSourceRef {
  surface: string;
  authority: string;
  path_refs: string[];
}

export interface GuiResponseEnvelope<TData> {
  ok: boolean;
  operation_id: GuiOperationId;
  source: GuiSourceRef;
  data: TData;
  warnings: string[];
  errors: string[];
  redactions: string[];
  observed_at: string;
}

export interface GuiRouteManifest {
  route: string;
  method: "GET";
  operation_id: GuiOperationId;
  classification: GuiRouteClassification;
  source_surface: string;
  adapter: string;
  command_pattern: readonly string[];
  redactions: readonly string[];
}

export interface GuiFileRootDefinition {
  id: GuiFileRootId;
  label: string;
  path_ref: string;
  description: string;
  preview_policy: "agents_markdown_and_code" | "metadata_only";
}

export interface GuiFileEntry {
  name: string;
  kind: "directory" | "file";
  path_ref: string;
  relative_path: string;
  extension: string;
  preview_allowed: boolean;
}

export interface GuiFilePreview {
  path_ref: string;
  relative_path: string;
  mode: "markdown" | "code" | "text" | "blocked";
  language: string;
  content: string;
  truncated: boolean;
  reason: string;
}

export interface GuiFileExplorerData {
  root: GuiFileRootDefinition;
  current_path_ref: string;
  current_relative_path: string;
  entries: GuiFileEntry[];
  selected_preview: GuiFilePreview | null;
  entry_limit: number;
}

export interface GuiSecretReference {
  name: string;
  status: "configured" | "missing" | "unchecked";
}

export interface GuiNavigationItem {
  id: string;
  label: string;
  description: string;
}

export interface GuiSettingsSummary {
  path_ref: string;
  health: "present" | "missing" | "invalid" | "unchecked";
  key_count: number;
  keys: string[];
  value_policy: "keys_only_no_values";
}

export interface GuiRepoSummary {
  name: string;
  platform: string;
  slug: string;
  local_path_status: "present" | "missing" | "not_provided" | "unchecked";
}

export interface GuiRepoRegistrySummary {
  path_ref: string;
  health: "present" | "missing" | "invalid" | "unchecked";
  total: number;
  repos: GuiRepoSummary[];
}

export interface GuiLocalRepoRemote {
  name: string;
  url_ref: string;
}

export interface GuiLocalRepoSetupSummary {
  name: string;
  path_ref: string;
  aidevops_version: string;
  default_branch: string;
  remotes: GuiLocalRepoRemote[];
  registered: boolean;
  pulse: boolean | null;
  local_only: boolean;
  init_scope: string;
  knowledge: string;
  priority: string;
  has_interface: boolean | null;
  features: string[];
  settings_policy: "read_only_no_writes";
}

export interface GuiLocalReposSetupSummary {
  path_ref: string;
  health: "present" | "missing" | "invalid" | "unchecked";
  total: number;
  excluded_worktrees: number;
  repos: GuiLocalRepoSetupSummary[];
}

export type GuiAiProviderId = "anthropic" | "openai" | "cursor" | "google";

export interface GuiOAuthPoolAccountSummary {
  email_ref: string;
  status: string;
  priority: number | null;
  last_used: string;
  expires_at: string;
  cooldown_until: string | null;
}

export interface GuiOAuthProviderSummary {
  provider: GuiAiProviderId;
  configured: boolean;
  total: number;
  available: number;
  active_or_idle: number;
  rate_limited: number;
  auth_errors: number;
  pending_token: boolean;
  accounts: GuiOAuthPoolAccountSummary[];
}

export interface GuiOAuthPoolSummary {
  path_ref: string;
  health: "present" | "missing" | "invalid" | "unchecked";
  value_policy: "metadata_only_no_tokens";
  providers: GuiOAuthProviderSummary[];
}

export interface GuiSetupTargetSummary {
  label: string;
  path_ref: string;
  health: "present" | "missing" | "unchecked";
  purpose: string;
  installed_version: string;
  latest_version: string;
  needs_update: boolean;
}

export interface GuiAiAppSummary {
  name: string;
  status: "found" | "missing" | "unchecked";
  app_path_ref: string;
  binary_path_ref: string;
  config_path_ref: string;
  aidevops_target_path_ref: string;
  app_version: string;
  aidevops_version: string;
  latest_version: string;
  needs_update: boolean;
}

export interface GuiCapabilitySummary {
  id: string;
  label: string;
  status: "available" | "planned" | "placeholder";
  doc_ref: string;
}

export interface GuiMachineSummary {
  id: string;
  label: string;
  initials: string;
  username: string;
  hostname: string;
  local_ips: string[];
  public_ip: string | null;
}

export interface GuiStatusData {
  aidevops_version: string;
  update: {
    running_version: string;
    installed_version: string;
    restart_required: boolean;
    message: string;
  };
  runtime: {
    host: "local";
    api: "hono";
    read_only: true;
  };
  machine: GuiMachineSummary;
  paths: Array<{
    label: string;
    path_ref: string;
    health: "present" | "missing" | "unchecked";
  }>;
  helper_availability: Array<{
    name: string;
    status: "available" | "missing" | "unchecked";
  }>;
  navigation: GuiNavigationItem[];
  settings: GuiSettingsSummary;
  repos: GuiRepoRegistrySummary;
  local_repos: GuiLocalReposSetupSummary;
  oauth_pool: GuiOAuthPoolSummary;
  setup_targets: GuiSetupTargetSummary[];
  ai_apps: GuiAiAppSummary[];
  capabilities: GuiCapabilitySummary[];
  secrets: GuiSecretReference[];
  placeholders: string[];
}

export const STATUS_ROUTE_MANIFEST: GuiRouteManifest = {
  route: "/api/status",
  method: "GET",
  operation_id: "setup.status.read",
  classification: "read",
  source_surface: "setup",
  adapter: "statusAdapter.readStatus",
  command_pattern: ["aidevops", "status"],
  redactions: ["secret_values", "credential_paths", "private_key_material"],
};

export const FILE_EXPLORER_ROUTE_MANIFEST: GuiRouteManifest = {
  route: "/api/files/:root",
  method: "GET",
  operation_id: "filesystem.read",
  classification: "read",
  source_surface: "filesystem",
  adapter: "fileAdapter.readFileExplorer",
  command_pattern: ["node:fs", "read-only", "root-allowlist"],
  redactions: ["secret_values", "credential_paths", "private_key_material"],
};

export const GUI_FILE_ROOTS: readonly GuiFileRootDefinition[] = [
  {
    id: "agents",
    label: "Agents",
    path_ref: "~/.aidevops/agents",
    description: "Agent, workflow, tool, service, and reference files deployed by aidevops.",
    preview_policy: "agents_markdown_and_code",
  },
  {
    id: "config",
    label: "Config",
    path_ref: "~/.config/aidevops",
    description: "Local aidevops configuration files. Contents stay hidden until a redaction policy lands.",
    preview_policy: "metadata_only",
  },
  {
    id: "localSetup",
    label: "Local Setup",
    path_ref: "~/.aidevops",
    description: "Local aidevops runtime folders, cache, memory, logs, and deployed assets.",
    preview_policy: "metadata_only",
  },
  {
    id: "git",
    label: "Git",
    path_ref: "~/Git",
    description: "Local git workspace roots and worktrees.",
    preview_policy: "metadata_only",
  },
] as const;

export const BANNED_ROUTE_PATTERNS = [
  "/shell",
  "/exec",
  "/terminal",
  "/run",
  "/run-command",
] as const;

export const SECRET_SENTINELS = [
  "SECRET_SENTINEL_DO_NOT_RENDER",
  "-----BEGIN PRIVATE KEY-----",
  "Bearer fake-token-value",
  "sessionid=fake-cookie-value",
  "/tmp/fake/credentials.json",
] as const;

export function createEnvelope<TData>(input: {
  operation_id: GuiOperationId;
  source: GuiSourceRef;
  data: TData;
  warnings?: string[];
  errors?: string[];
  observed_at?: string;
}): GuiResponseEnvelope<TData> {
  return {
    ok: input.errors === undefined || input.errors.length === 0,
    operation_id: input.operation_id,
    source: input.source,
    data: input.data,
    warnings: input.warnings ?? [],
    errors: input.errors ?? [],
    redactions: ["secret_values", "credential_paths", "private_key_material"],
    observed_at: input.observed_at ?? new Date().toISOString(),
  };
}

export function containsSecretSentinel(value: unknown): boolean {
  const serialized = JSON.stringify(value);
  return SECRET_SENTINELS.some((sentinel) => serialized.includes(sentinel));
}

export function assertNoSecretSentinels(value: unknown): void {
  if (containsSecretSentinel(value)) {
    throw new Error("Secret sentinel leaked into GUI payload");
  }
}

export function isReadOnlyManifest(manifest: GuiRouteManifest): boolean {
  return manifest.method === "GET" && manifest.classification === "read";
}
