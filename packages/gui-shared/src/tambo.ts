import type { GuiConversationScope, GuiRouteManifest } from "./contracts";

export type GuiTamboComponentName = "TaskCard" | "PullRequestCard" | "CICheckSummary" | "WorkerStatusCard" | "DeploymentStatusCard" | "RepoHealthCard" | "ApprovalPromptCard";

export type GuiTamboComponentMode = "read_only" | "request_only";

export type GuiTamboPropType = "string" | "number" | "boolean" | "string_array";

export interface GuiTamboPropSchema {
  type: GuiTamboPropType;
  required: boolean;
}

export interface GuiTamboComponentSchema {
  name: GuiTamboComponentName;
  description: string;
  mode: GuiTamboComponentMode;
  additionalProperties: false;
  properties: Record<string, GuiTamboPropSchema>;
}

export interface GuiTamboComponentPayload {
  component: GuiTamboComponentName;
  tenant_ref: string;
  session_ref: string;
  read_only: boolean;
  props: Record<string, unknown>;
}

export interface GuiTamboValidationResult {
  ok: boolean;
  component: GuiTamboComponentName | null;
  props: Record<string, unknown>;
  errors: string[];
}

export interface GuiTamboProviderConfig {
  provider: "tambo";
  proxy_route: string;
  secret_policy: "server_only_no_browser_tokens";
  thread_key_policy: "tenant_workspace_session_scoped";
  components: GuiTamboComponentSchema[];
  deferred_interactables: string[];
}

export const TAMBO_PROXY_ROUTE_MANIFEST: GuiRouteManifest = {
  route: "/api/tambo/session",
  method: "GET",
  operation_id: "tambo.session.read",
  classification: "read",
  source_surface: "conversations",
  adapter: "tambo.readProviderConfig",
  command_pattern: ["server-proxied", "metadata-only", "no-browser-secrets"],
  redactions: ["secret_values", "credential_paths", "private_key_material", "tambo_api_keys"],
};

export const TAMBO_COMPONENT_SCHEMAS: readonly GuiTamboComponentSchema[] = [
  {
    name: "TaskCard",
    description: "Read-only task or issue status card.",
    mode: "read_only",
    additionalProperties: false,
    properties: {
      title: { type: "string", required: true },
      status: { type: "string", required: true },
      priority: { type: "string", required: false },
      owner: { type: "string", required: false },
      repo: { type: "string", required: false },
      reference: { type: "string", required: false },
    },
  },
  {
    name: "PullRequestCard",
    description: "Read-only pull request summary card.",
    mode: "read_only",
    additionalProperties: false,
    properties: {
      title: { type: "string", required: true },
      status: { type: "string", required: true },
      branch: { type: "string", required: false },
      checks: { type: "string", required: false },
      review: { type: "string", required: false },
      reference: { type: "string", required: false },
    },
  },
  {
    name: "CICheckSummary",
    description: "Read-only CI status summary card.",
    mode: "read_only",
    additionalProperties: false,
    properties: {
      status: { type: "string", required: true },
      passed: { type: "number", required: true },
      failed: { type: "number", required: true },
      pending: { type: "number", required: false },
      summary: { type: "string", required: false },
    },
  },
  {
    name: "WorkerStatusCard",
    description: "Read-only worker progress card.",
    mode: "read_only",
    additionalProperties: false,
    properties: {
      worker: { type: "string", required: true },
      status: { type: "string", required: true },
      task: { type: "string", required: false },
      progress: { type: "number", required: false },
      blockers: { type: "string_array", required: false },
    },
  },
  {
    name: "DeploymentStatusCard",
    description: "Read-only deployment environment status card.",
    mode: "read_only",
    additionalProperties: false,
    properties: {
      environment: { type: "string", required: true },
      status: { type: "string", required: true },
      version: { type: "string", required: false },
      health: { type: "string", required: false },
    },
  },
  {
    name: "RepoHealthCard",
    description: "Read-only repository health card.",
    mode: "read_only",
    additionalProperties: false,
    properties: {
      repo: { type: "string", required: true },
      status: { type: "string", required: true },
      open_prs: { type: "number", required: false },
      failing_checks: { type: "number", required: false },
      notes: { type: "string_array", required: false },
    },
  },
  {
    name: "ApprovalPromptCard",
    description: "Request-only approval card. Mutating approval execution is deferred until audited approval tooling exists.",
    mode: "request_only",
    additionalProperties: false,
    properties: {
      action: { type: "string", required: true },
      reason: { type: "string", required: true },
      risk: { type: "string", required: true },
      requested_by: { type: "string", required: false },
      disabled: { type: "boolean", required: true },
    },
  },
] as const;

export const TAMBO_PROVIDER_CONFIG: GuiTamboProviderConfig = {
  provider: "tambo",
  proxy_route: TAMBO_PROXY_ROUTE_MANIFEST.route,
  secret_policy: "server_only_no_browser_tokens",
  thread_key_policy: "tenant_workspace_session_scoped",
  components: [...TAMBO_COMPONENT_SCHEMAS],
  deferred_interactables: ["mutating approvals", "deployment actions", "PR merge/retry actions", "worker dispatch writes"],
};

export function validateTamboComponentPayload(payload: unknown, scope: GuiConversationScope): GuiTamboValidationResult {
  if (!isRecord(payload)) {
    return invalid(null, {}, "payload_not_object");
  }
  if (typeof payload.component !== "string") {
    return invalid(null, {}, "component_missing");
  }
  const schema = TAMBO_COMPONENT_SCHEMAS.find((candidate) => candidate.name === payload.component);
  if (schema === undefined) {
    return invalid(null, {}, "component_not_registered");
  }
  if (payload.tenant_ref !== scope.tenant_ref) {
    return invalid(schema.name, {}, "tenant_scope_mismatch");
  }
  if (typeof payload.session_ref !== "string" || payload.session_ref.length === 0) {
    return invalid(schema.name, {}, "session_ref_missing");
  }
  if (payload.read_only !== true) {
    return invalid(schema.name, {}, "component_not_read_only");
  }
  if (!isRecord(payload.props)) {
    return invalid(schema.name, {}, "props_not_object");
  }

  const errors: string[] = [];
  const props = payload.props;
  for (const key of Object.keys(props)) {
    if (schema.properties[key] === undefined) {
      errors.push(`unexpected_prop:${key}`);
    }
  }
  for (const [key, propSchema] of Object.entries(schema.properties)) {
    const value = props[key];
    if (value === undefined) {
      if (propSchema.required) {
        errors.push(`missing_prop:${key}`);
      }
      continue;
    }
    if (!valueMatchesType(value, propSchema.type)) {
      errors.push(`invalid_prop:${key}`);
    }
  }
  if (schema.name === "ApprovalPromptCard" && props.disabled !== true) {
    errors.push("approval_prompt_must_be_disabled");
  }

  return { ok: errors.length === 0, component: schema.name, props, errors };
}

function invalid(component: GuiTamboComponentName | null, props: Record<string, unknown>, error: string): GuiTamboValidationResult {
  return { ok: false, component, props, errors: [error] };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function valueMatchesType(value: unknown, type: GuiTamboPropType): boolean {
  if (type === "string_array") {
    return Array.isArray(value) && value.every((entry) => typeof entry === "string");
  }
  return typeof value === type;
}
