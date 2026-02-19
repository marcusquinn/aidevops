/**
 * Tenant Context Model
 *
 * Task: t004.1 — Design multi-org data isolation schema and tenant context model
 *
 * Defines how tenant (organisation) context flows through the application:
 * - Resolution chain (how org context is determined per request)
 * - TenantContext type (immutable, passed through call chain)
 * - Middleware interface (for t004.2 implementation)
 * - RLS setup helpers (for database-level enforcement)
 *
 * This module is consumed by:
 * - t004.2: Middleware implementation
 * - t004.3: Org-switching UI
 * - t004.4: AI context isolation
 * - t004.5: Integration tests
 */

import type { SQL } from 'drizzle-orm';
import { sql } from 'drizzle-orm';

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

export type OrgRole = 'owner' | 'admin' | 'member' | 'viewer';
export type OrgPlan = 'free' | 'pro' | 'enterprise';

/**
 * How the org context was resolved. Used for audit logging and debugging.
 */
export type TenantResolutionMethod =
  | 'header' // X-Org-Id request header (API calls, worker dispatch)
  | 'session' // org_id claim in JWT or session store
  | 'url' // /org/:slug/... path parameter
  | 'project_config' // .aidevops-tenant file (CLI/local dev)
  | 'user_default' // users.last_active_org_id
  | 'single_org'; // User belongs to exactly one org

/**
 * Immutable tenant context — created once per request, passed through
 * the entire call chain. Never mutated after creation.
 *
 * This is the primary interface consumed by route handlers, services,
 * and middleware. All org-scoped operations receive this context.
 */
export interface TenantContext {
  /** Organisation ID (UUID) — used for all DB queries */
  readonly orgId: string;
  /** Organisation slug — used for URL routing, display */
  readonly orgSlug: string;
  /** User ID — the authenticated user */
  readonly userId: string;
  /** User's role in this organisation */
  readonly role: OrgRole;
  /** How the org context was resolved */
  readonly resolvedVia: TenantResolutionMethod;
  /** Organisation plan (affects feature gates) */
  readonly plan: OrgPlan;
}

// ---------------------------------------------------------------------------
// Resolution chain
// ---------------------------------------------------------------------------

/**
 * A resolver attempts to extract an org identifier from the request.
 * Returns the org slug or ID if found, null otherwise.
 * Resolvers are tried in priority order; first non-null wins.
 */
export interface TenantResolver {
  readonly method: TenantResolutionMethod;
  resolve(req: TenantResolverInput): Promise<string | null>;
}

/**
 * Input provided to each resolver. Abstracted from any specific
 * HTTP framework (Express, Hono, Fastify, etc.).
 */
export interface TenantResolverInput {
  /** Request headers (lowercase keys) */
  headers: Record<string, string | undefined>;
  /** URL path */
  path: string;
  /** Session/cookie data (if available) */
  session?: { orgId?: string; userId?: string };
  /** Authenticated user ID (from auth middleware) */
  userId?: string;
}

/**
 * Default resolver chain — ordered by priority.
 * t004.2 implements these; this defines the interface contract.
 */
export const DEFAULT_RESOLVER_ORDER: TenantResolutionMethod[] = [
  'header',
  'session',
  'url',
  'project_config',
  'user_default',
  'single_org',
];

// ---------------------------------------------------------------------------
// Middleware interface
// ---------------------------------------------------------------------------

/**
 * Result of tenant resolution. Either a valid context or an error.
 */
export type TenantResolutionResult =
  | { ok: true; context: TenantContext }
  | { ok: false; error: TenantResolutionError };

export type TenantResolutionError =
  | { code: 'NO_AUTH'; message: string }
  | { code: 'NO_ORG_CONTEXT'; message: string }
  | { code: 'ORG_NOT_FOUND'; message: string }
  | { code: 'NOT_A_MEMBER'; message: string }
  | { code: 'MEMBERSHIP_SUSPENDED'; message: string };

/**
 * Tenant middleware contract — implemented by t004.2.
 *
 * Usage in route handler:
 * ```typescript
 * app.get('/api/data', async (req, res) => {
 *   const tenant = req.tenant; // TenantContext, set by middleware
 *   const data = await db.select().from(table)
 *     .where(eq(table.orgId, tenant.orgId));
 * });
 * ```
 */
export interface TenantMiddleware {
  /**
   * Resolve tenant context from request.
   * Sets RLS variables on the database connection.
   * Attaches TenantContext to the request object.
   */
  resolve(req: TenantResolverInput): Promise<TenantResolutionResult>;
}

// ---------------------------------------------------------------------------
// RLS helpers
// ---------------------------------------------------------------------------

/**
 * SQL statements to set RLS context variables per request.
 * Called by tenant middleware before any org-scoped query.
 *
 * Uses PostgreSQL `set_config` with `is_local = true` so the setting
 * is scoped to the current transaction only.
 */
export function setRlsContext(orgId: string, userId: string): SQL[] {
  return [
    sql`SELECT set_config('app.current_org_id', ${orgId}, true)`,
    sql`SELECT set_config('app.current_user_id', ${userId}, true)`,
  ];
}

/**
 * SQL statements to clear RLS context (e.g., for superadmin operations).
 */
export function clearRlsContext(): SQL[] {
  return [
    sql`SELECT set_config('app.current_org_id', '', true)`,
    sql`SELECT set_config('app.current_user_id', '', true)`,
  ];
}

// ---------------------------------------------------------------------------
// Permission helpers
// ---------------------------------------------------------------------------

/**
 * Role hierarchy — higher index = more permissions.
 */
const ROLE_HIERARCHY: Record<OrgRole, number> = {
  viewer: 0,
  member: 1,
  admin: 2,
  owner: 3,
};

/**
 * Check if a role has at least the required permission level.
 *
 * @example
 * hasPermission('admin', 'member') // true — admin >= member
 * hasPermission('viewer', 'member') // false — viewer < member
 */
export function hasPermission(
  userRole: OrgRole,
  requiredRole: OrgRole,
): boolean {
  return ROLE_HIERARCHY[userRole] >= ROLE_HIERARCHY[requiredRole];
}

/**
 * Permission requirements for common operations.
 * Used by route handlers to gate access.
 */
export const PERMISSIONS = {
  // Credential operations
  'credentials:read': 'member' as OrgRole,
  'credentials:write': 'admin' as OrgRole,
  'credentials:delete': 'admin' as OrgRole,

  // Member management
  'members:read': 'member' as OrgRole,
  'members:invite': 'admin' as OrgRole,
  'members:remove': 'admin' as OrgRole,
  'members:change_role': 'owner' as OrgRole,

  // Org settings
  'settings:read': 'member' as OrgRole,
  'settings:write': 'admin' as OrgRole,

  // AI sessions
  'ai_sessions:read_own': 'member' as OrgRole,
  'ai_sessions:read_all': 'admin' as OrgRole,

  // Audit log
  'audit:read': 'admin' as OrgRole,

  // Org lifecycle
  'org:delete': 'owner' as OrgRole,
  'org:transfer': 'owner' as OrgRole,
} as const;

// ---------------------------------------------------------------------------
// Org switching
// ---------------------------------------------------------------------------

/**
 * Steps required when a user switches organisations.
 * Implemented by t004.3 (UI) and consumed by t004.4 (AI isolation).
 *
 * This is a specification — the actual implementation lives in the
 * middleware and UI layers.
 */
export interface OrgSwitchSpec {
  /** 1. Verify user has membership in target org */
  verifyMembership: (userId: string, targetOrgId: string) => Promise<boolean>;
  /** 2. Update users.last_active_org_id */
  updateLastActiveOrg: (userId: string, orgId: string) => Promise<void>;
  /** 3. Issue new session with updated org_id claim */
  refreshSession: (userId: string, orgId: string) => Promise<string>;
  /** 4. Clear org-specific caches */
  clearOrgCaches: (orgId: string) => Promise<void>;
}

// ---------------------------------------------------------------------------
// Worker/headless context
// ---------------------------------------------------------------------------

/**
 * For autonomous workers dispatched by the supervisor.
 * The org context is set via environment or dispatch prompt.
 */
export interface WorkerTenantConfig {
  /** Org ID from dispatch metadata */
  orgId: string;
  /** User ID of the user who initiated the task */
  userId: string;
  /** How credentials are loaded */
  credentialSource: 'env' | 'credential_helper' | 'database';
}

/**
 * Create a TenantContext for a headless worker.
 * Workers always resolve via 'header' method (explicit org assignment).
 */
export function createWorkerContext(
  config: WorkerTenantConfig & { orgSlug: string; role: OrgRole; plan: OrgPlan },
): TenantContext {
  return Object.freeze({
    orgId: config.orgId,
    orgSlug: config.orgSlug,
    userId: config.userId,
    role: config.role,
    resolvedVia: 'header',
    plan: config.plan,
  });
}
