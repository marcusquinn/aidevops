export type GuiRouteClassification = "read" | "write" | "destructive";

export type GuiOperationId = "setup.status.read" | "capabilities.read";

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

export interface GuiSecretReference {
  name: string;
  status: "configured" | "missing" | "unchecked";
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
  paths: Array<{
    label: string;
    path_ref: string;
    health: "present" | "missing" | "unchecked";
  }>;
  helper_availability: Array<{
    name: string;
    status: "available" | "missing" | "unchecked";
  }>;
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
