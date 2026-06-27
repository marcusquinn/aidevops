export type GuiRouteClassification = "read" | "write" | "destructive";

export type GuiOperationId = "setup.status.read" | "capabilities.read" | "filesystem.read" | "vault.status.read" | "apps.action.run" | "apps.action.status";

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
  method: "GET" | "POST";
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

export type GuiAppActionId = "install" | "update" | "reinstall" | "remove";

export interface GuiManagedAppActionSummary {
  id: GuiAppActionId;
  label: string;
  enabled: boolean;
  command_preview: string;
  confirmation: "none" | "recommended" | "required";
}

export interface GuiManagedAppSummary {
  id: string;
  name: string;
  description: string;
  category: string;
  origin_website_url: string;
  origin_repo_url: string;
  aidevops_install: boolean;
  aidevops_update: boolean;
  installed_version: string;
  latest_version: string;
  install_path_ref: string;
  status: "found" | "missing" | "unchecked";
  actions: GuiManagedAppActionSummary[];
}

export interface GuiAppActionJobSummary {
  id: string;
  app_id: string;
  action: GuiAppActionId;
  status: "running" | "completed" | "failed" | "rejected";
  command_preview: string;
  started_at: string;
  finished_at: string | null;
  exit_code: number | null;
  output: string[];
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

export interface GuiOpenCodeSessionSummary {
  id_ref: string;
  repo_path_ref: string;
  title: string;
  updated_at: string;
  model: string;
  agent: string;
}

export interface GuiOpenCodeSessionRegistrySummary {
  path_ref: string;
  health: "present" | "missing" | "invalid" | "unchecked";
  value_policy: "metadata_only_no_message_payloads";
  sessions: GuiOpenCodeSessionSummary[];
}

export type GuiConversationType = "ai_session" | "channel" | "dm" | "group_dm" | "worker_thread";

export type GuiConversationParticipantKind = "human" | "ai_assistant" | "worker" | "system_bot";

export type GuiConversationMessageSenderKind = GuiConversationParticipantKind | "system";

export type GuiConversationMessagePartKind = "text" | "file" | "tool_call" | "source" | "tambo_component" | "approval_prompt" | "event_marker";

export interface GuiConversationScope {
  tenant_ref: string;
  workspace_ref: string;
  repo_ref: string | null;
}

export interface GuiConversation {
  id: string;
  type: GuiConversationType;
  title: string;
  scope: GuiConversationScope;
  source_ref: string;
  status: "active" | "archived" | "read_only";
  created_at: string;
  updated_at: string;
}

export interface GuiConversationParticipant {
  id: string;
  conversation_id: string;
  kind: GuiConversationParticipantKind;
  display_name: string;
  identity_ref: string | null;
  agent_ref: string | null;
  worker_ref: string | null;
  membership_state: "active" | "invited" | "left" | "removed";
  joined_at: string;
}

export interface GuiConversationUsageMetadata {
  provider_ref: string | null;
  model_ref: string | null;
  input_tokens: number;
  output_tokens: number;
  total_tokens: number;
  cost_ref: string | null;
}

export interface GuiConversationMessage {
  id: string;
  conversation_id: string;
  sender_participant_id: string | null;
  sender_kind: GuiConversationMessageSenderKind;
  sequence: number;
  status: "draft" | "sent" | "delivered" | "failed" | "redacted";
  usage: GuiConversationUsageMetadata | null;
  created_at: string;
  edited_at: string | null;
}

export interface GuiConversationMessagePart {
  id: string;
  message_id: string;
  kind: GuiConversationMessagePartKind;
  ordinal: number;
  text: string | null;
  payload_json: Record<string, unknown> | null;
  file_ref: string | null;
  source_ref: string | null;
}

export interface GuiConversationReaction {
  id: string;
  message_id: string;
  participant_id: string;
  reaction: string;
  created_at: string;
}

export interface GuiConversationReadState {
  conversation_id: string;
  participant_id: string;
  last_read_message_id: string | null;
  last_read_sequence: number;
  updated_at: string;
}

export interface GuiConversationThread {
  conversation: GuiConversation;
  participants: GuiConversationParticipant[];
  messages: GuiConversationMessage[];
  parts: GuiConversationMessagePart[];
  reactions: GuiConversationReaction[];
  read_states: GuiConversationReadState[];
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

export type GuiNotificationSeverity = "success" | "info" | "warning" | "error";

export type GuiNotificationCategory = "security" | "maintenance" | "release" | "runtime" | "setup";

export interface GuiNotificationAction {
  id: string;
  label: string;
  kind: "surface" | "command";
  surface_id?: string;
  command_preview?: string;
  enabled: boolean;
}

export interface GuiNotificationSummary {
  id: string;
  title: string;
  message: string;
  severity: GuiNotificationSeverity;
  category: GuiNotificationCategory;
  source: "opencode-toast" | "gui-status";
  source_ref: string;
  status: "active" | "resolved";
  actions: GuiNotificationAction[];
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

export type GuiVaultStatus = "uninitialized" | "locked" | "unlocked" | "corrupted" | "unknown";

export type GuiVaultSetupState = "uninitialized" | "test-created" | "restart-required" | "test-verified" | "migration-ready" | "unknown";

export type GuiVaultEncryptionState = "not_configured" | "locked" | "unlocked" | "planned" | "unknown";

export interface GuiVaultCollectionSummary {
  id: string;
  label: string;
  data_class: string;
  labels: string[];
  surface_ids: string[];
  encrypted: boolean;
  state: GuiVaultEncryptionState;
  preview_policy: "hidden_while_locked" | "metadata_only" | "placeholder_only";
  actions_policy: "disabled_while_locked" | "read_only" | "placeholder_disabled";
}

export interface GuiVaultReadinessSummary {
  migration_allowed: boolean;
  setup_required: boolean;
  restart_test_required: boolean;
  remote_unlock_enabled: boolean;
  provider_routing_enforced: boolean;
  locked_content_hidden: boolean;
}

export interface GuiVaultDeviceSummary {
  id_ref: string;
  label: string;
  trust_state: "local" | "pending" | "trusted" | "limited" | "revoked" | "retired" | "planned" | "unknown";
  last_seen: string;
  audit_head_ref: string;
}

export interface GuiVaultSyncSummary {
  status: "not_configured" | "planned" | "ready" | "error" | "unknown";
  transport_policy: "encrypted_only_untrusted_transport";
  encrypted_collections: number;
  pending_requests: number;
}

export interface GuiVaultAuditSummary {
  status: "not_started" | "planned" | "recording" | "error" | "unknown";
  event_count: number;
  latest_event_ref: string;
}

export interface GuiVaultStatusData {
  status: GuiVaultStatus;
  setup_state: GuiVaultSetupState;
  initialized: boolean;
  locked: boolean;
  unlocked: boolean;
  available: boolean;
  helper_status: "available" | "missing" | "error" | "unchecked";
  path_ref: string;
  value_policy: "metadata_only_no_secret_material";
  tooltip: string;
  unlock_hint: string;
  setup_hint: string;
  readiness: GuiVaultReadinessSummary;
  collections: GuiVaultCollectionSummary[];
  devices: GuiVaultDeviceSummary[];
  sync: GuiVaultSyncSummary;
  secure_messages: GuiVaultSyncSummary;
  backups: GuiVaultSyncSummary;
  audit: GuiVaultAuditSummary;
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
  opencode_sessions: GuiOpenCodeSessionRegistrySummary;
  oauth_pool: GuiOAuthPoolSummary;
  setup_targets: GuiSetupTargetSummary[];
  ai_apps: GuiAiAppSummary[];
  managed_apps: GuiManagedAppSummary[];
  notifications: GuiNotificationSummary[];
  vault: GuiVaultStatusData;
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

export const VAULT_STATUS_ROUTE_MANIFEST: GuiRouteManifest = {
  route: "/api/vault/status",
  method: "GET",
  operation_id: "vault.status.read",
  classification: "read",
  source_surface: "vault",
  adapter: "statusAdapter.readVaultStatus",
  command_pattern: ["aidevops", "vault", "status"],
  redactions: ["secret_values", "credential_paths", "private_key_material", "vault_passphrases", "recovery_material"],
};

export const APP_ACTION_ROUTE_MANIFEST: GuiRouteManifest = {
  route: "/api/apps/:appId/actions/:action",
  method: "POST",
  operation_id: "apps.action.run",
  classification: "write",
  source_surface: "apps",
  adapter: "appActions.startAppAction",
  command_pattern: ["allowlisted", "aidevops", "setup/update", "background-job"],
  redactions: ["secret_values", "credential_paths", "private_key_material"],
};

export const APP_ACTION_STATUS_ROUTE_MANIFEST: GuiRouteManifest = {
  route: "/api/apps/jobs/:jobId",
  method: "GET",
  operation_id: "apps.action.status",
  classification: "read",
  source_surface: "apps",
  adapter: "appActions.readAppActionJob",
  command_pattern: ["background-job", "metadata-and-output-only"],
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
    redactions: ["secret_values", "credential_paths", "private_key_material", "vault_passphrases", "recovery_material"],
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

export function sortConversationMessages<TMessage extends Pick<GuiConversationMessage, "sequence" | "created_at">>(messages: TMessage[]): TMessage[] {
  return [...messages].sort((left, right) => left.sequence - right.sequence || left.created_at.localeCompare(right.created_at));
}

export function sortConversationMessageParts<TPart extends Pick<GuiConversationMessagePart, "ordinal">>(parts: TPart[]): TPart[] {
  return [...parts].sort((left, right) => left.ordinal - right.ordinal);
}

export function participantCanReadConversation(thread: GuiConversationThread, participantId: string): boolean {
  return thread.participants.some((participant) => participant.id === participantId && participant.membership_state === "active");
}

export function conversationHasScope(thread: GuiConversationThread, scope: GuiConversationScope): boolean {
  return thread.conversation.scope.tenant_ref === scope.tenant_ref && thread.conversation.scope.workspace_ref === scope.workspace_ref && thread.conversation.scope.repo_ref === scope.repo_ref;
}
