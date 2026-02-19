---
description: Multi-org data isolation schema and tenant context model
mode: subagent
model: sonnet
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

# Multi-Org Data Isolation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Schema**: `.agents/services/database/schemas/multi-org.ts`
- **Context model**: `.agents/services/database/schemas/tenant-context.ts`
- **Config template**: `configs/multi-org-config.json.txt`
- **Helper**: `.agents/scripts/multi-org-helper.sh`
- **Isolation strategy**: Row-level with `org_id` foreign key on all tenant-scoped tables
- **Context resolution**: Request header > session > project config > default org

**Sibling tasks**:

- t004.2: Implements tenant-scoped queries and middleware from this schema
- t004.3: Implements org-switching UI using the context model
- t004.4: Implements AI context isolation per organisation
- t004.5: Integration tests for data boundaries

<!-- AI-CONTEXT-END -->

## Architecture Overview

### Isolation Strategy: Row-Level Tenancy

We use **row-level tenancy** (shared database, shared schema, `org_id` column) rather than
schema-per-tenant or database-per-tenant. Rationale:

| Strategy | Pros | Cons | When to use |
|----------|------|------|-------------|
| **Row-level** (chosen) | Simple ops, easy cross-org queries for superadmin, single migration path | Requires discipline on every query | <1000 orgs, shared infrastructure |
| Schema-per-tenant | Strong isolation, easy per-tenant backup | Migration complexity, connection pooling | Regulated industries |
| Database-per-tenant | Strongest isolation | Operational nightmare at scale | Enterprise with dedicated infra |

Row-level is the right choice for aidevops because:

1. Organisations share the same feature set (no per-tenant customisation)
2. Superadmin needs cross-org visibility for framework operations
3. Single migration path keeps the framework simple
4. PostgreSQL Row-Level Security (RLS) provides enforcement at the database level

### Data Classification

All tables fall into one of three categories:

| Category | `org_id` column | RLS policy | Examples |
|----------|----------------|------------|---------|
| **Org-scoped** | Required, NOT NULL | Enforced | credentials, projects, ai_sessions, api_keys |
| **Org-optional** | Nullable | Conditional | memories, patterns (can be global or org-specific) |
| **Global** | None | None | organisations, users, system_config |

## Schema Design

### Entity Relationship

```text
organisations 1──* org_memberships *──1 users
     │                                    │
     │ org_id                             │ user_id
     ├──* credentials                     │
     ├──* projects                        │
     ├──* ai_sessions ────────────────────┘
     ├──* api_key_sets
     ├──* org_settings
     └──* audit_log
```

### Core Tables

#### organisations

The root tenant entity. Every org-scoped record references this.

```typescript
export const organisations = pgTable('organisations', {
  id: uuid('id').primaryKey().defaultRandom(),
  slug: varchar('slug', { length: 63 }).notNull().unique(),
  name: text('name').notNull(),
  plan: text('plan', { enum: ['free', 'pro', 'enterprise'] })
    .notNull().default('free'),
  settings: jsonb('settings').$type<OrgSettings>().default({}),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull().defaultNow().$onUpdate(() => new Date()),
});
```

**Design decisions**:

- `slug` is the URL-safe identifier (e.g., `acme-corp`), unique, used in routing
- `id` (UUID) is the foreign key target — never expose UUIDs in URLs
- `plan` uses text enum (easier to extend than pgEnum)
- `settings` JSONB for org-level preferences without schema migrations

#### users

Global user table — users exist independently of organisations.

```typescript
export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  email: varchar('email', { length: 255 }).notNull().unique(),
  name: text('name'),
  avatarUrl: text('avatar_url'),
  lastActiveOrgId: uuid('last_active_org_id')
    .references(() => organisations.id, { onDelete: 'set null' }),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull().defaultNow().$onUpdate(() => new Date()),
});
```

**Design decisions**:

- Users are global — a user can belong to multiple organisations
- `lastActiveOrgId` tracks the most recent org context for session restoration
- No password field — authentication is delegated (OAuth, passkeys, etc.)

#### org_memberships

Join table with role. This is the authorisation boundary.

```typescript
export const roleEnum = pgEnum('org_role', [
  'owner',    // Full control, can delete org
  'admin',    // Manage members, settings, all data
  'member',   // Read/write org data
  'viewer',   // Read-only access
]);

export const org_memberships = pgTable('org_memberships', {
  id: uuid('id').primaryKey().defaultRandom(),
  orgId: uuid('org_id').notNull()
    .references(() => organisations.id, { onDelete: 'cascade' }),
  userId: uuid('user_id').notNull()
    .references(() => users.id, { onDelete: 'cascade' }),
  role: roleEnum('role').notNull().default('member'),
  invitedBy: uuid('invited_by')
    .references(() => users.id, { onDelete: 'set null' }),
  joinedAt: timestamp('joined_at', { withTimezone: true })
    .notNull().defaultNow(),
}, (table) => [
  uniqueIndex('org_memberships_org_user_idx')
    .on(table.orgId, table.userId),
  index('org_memberships_user_idx').on(table.userId),
]);
```

**Design decisions**:

- Composite unique on `(org_id, user_id)` — one membership per org per user
- `role` uses pgEnum (fixed set, enforced at DB level)
- `cascade` on org/user delete — membership is meaningless without both
- `invitedBy` for audit trail

### Org-Scoped Tables Pattern

Every org-scoped table follows this pattern:

```typescript
// Reusable org-scoping columns
const orgScoped = {
  orgId: uuid('org_id').notNull()
    .references(() => organisations.id, { onDelete: 'cascade' }),
};

// Example: org-scoped credentials
export const org_credentials = pgTable('org_credentials', {
  id: uuid('id').primaryKey().defaultRandom(),
  ...orgScoped,
  service: varchar('service', { length: 100 }).notNull(),
  keyName: varchar('key_name', { length: 100 }).notNull(),
  // Encrypted value — never stored in plaintext
  encryptedValue: text('encrypted_value').notNull(),
  createdBy: uuid('created_by')
    .references(() => users.id, { onDelete: 'set null' }),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull().defaultNow().$onUpdate(() => new Date()),
}, (table) => [
  uniqueIndex('org_credentials_org_service_key_idx')
    .on(table.orgId, table.service, table.keyName),
  index('org_credentials_org_idx').on(table.orgId),
]);
```

### AI Session Isolation

Critical for t004.4 — AI sessions must be strictly org-scoped.

```typescript
export const ai_sessions = pgTable('ai_sessions', {
  id: uuid('id').primaryKey().defaultRandom(),
  ...orgScoped,
  userId: uuid('user_id').notNull()
    .references(() => users.id, { onDelete: 'cascade' }),
  model: varchar('model', { length: 100 }),
  // Session context — org-specific memories, patterns, preferences
  context: jsonb('context').$type<SessionContext>().default({}),
  startedAt: timestamp('started_at', { withTimezone: true })
    .notNull().defaultNow(),
  endedAt: timestamp('ended_at', { withTimezone: true }),
}, (table) => [
  index('ai_sessions_org_idx').on(table.orgId),
  index('ai_sessions_user_idx').on(table.userId),
  index('ai_sessions_org_user_idx').on(table.orgId, table.userId),
]);
```

### Org-Scoped Memory

Memories can be global (personal) or org-scoped (shared within org).

```typescript
export const memories = pgTable('memories', {
  id: uuid('id').primaryKey().defaultRandom(),
  orgId: uuid('org_id')
    .references(() => organisations.id, { onDelete: 'cascade' }),
  userId: uuid('user_id').notNull()
    .references(() => users.id, { onDelete: 'cascade' }),
  content: text('content').notNull(),
  confidence: text('confidence', { enum: ['low', 'medium', 'high'] })
    .notNull().default('medium'),
  namespace: varchar('namespace', { length: 100 }),
  accessCount: integer('access_count').notNull().default(0),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull().defaultNow(),
}, (table) => [
  index('memories_org_idx').on(table.orgId),
  index('memories_user_idx').on(table.userId),
  // Partial index: org-scoped memories only
  index('memories_org_scoped_idx')
    .on(table.orgId, table.userId)
    .where(sql`org_id IS NOT NULL`),
]);
```

### Audit Log

All org-scoped mutations are logged for compliance and debugging.

```typescript
export const audit_log = pgTable('audit_log', {
  id: uuid('id').primaryKey().defaultRandom(),
  orgId: uuid('org_id').notNull()
    .references(() => organisations.id, { onDelete: 'cascade' }),
  userId: uuid('user_id')
    .references(() => users.id, { onDelete: 'set null' }),
  action: varchar('action', { length: 100 }).notNull(),
  entityType: varchar('entity_type', { length: 100 }).notNull(),
  entityId: uuid('entity_id'),
  metadata: jsonb('metadata').$type<Record<string, unknown>>().default({}),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull().defaultNow(),
}, (table) => [
  index('audit_log_org_idx').on(table.orgId),
  index('audit_log_org_action_idx').on(table.orgId, table.action),
  index('audit_log_created_idx').on(table.createdAt),
]);
```

## Row-Level Security (RLS)

PostgreSQL RLS enforces isolation at the database level, independent of application code.
This is the safety net — even if application code has a bug, RLS prevents cross-org leaks.

### Setup

```sql
-- Enable RLS on all org-scoped tables
ALTER TABLE org_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE memories ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

-- Application role (used by the app, not superuser)
CREATE ROLE app_user;

-- Policy: users can only see rows for their current org
CREATE POLICY org_isolation ON org_credentials
  FOR ALL
  TO app_user
  USING (org_id = current_setting('app.current_org_id')::uuid);

CREATE POLICY org_isolation ON ai_sessions
  FOR ALL
  TO app_user
  USING (org_id = current_setting('app.current_org_id')::uuid);

-- Memories: org-scoped OR personal (org_id IS NULL and user owns it)
CREATE POLICY org_or_personal ON memories
  FOR ALL
  TO app_user
  USING (
    org_id = current_setting('app.current_org_id')::uuid
    OR (org_id IS NULL AND user_id = current_setting('app.current_user_id')::uuid)
  );

CREATE POLICY org_isolation ON audit_log
  FOR ALL
  TO app_user
  USING (org_id = current_setting('app.current_org_id')::uuid);
```

### Setting Context Per Request

```typescript
// In middleware (before any query)
await db.execute(
  sql`SELECT set_config('app.current_org_id', ${orgId}, true)`
);
await db.execute(
  sql`SELECT set_config('app.current_user_id', ${userId}, true)`
);
// `true` = local to transaction only
```

## Tenant Context Model

### Context Resolution Chain

The tenant context determines which organisation's data is accessed. Resolution follows
a priority chain (first match wins):

```text
1. Request header: X-Org-Id (API calls, worker dispatch)
2. Session/cookie: org_id claim in JWT or session store
3. URL path: /org/:slug/... (web UI routing)
4. Project config: .aidevops-tenant file (CLI/local dev)
5. User default: users.last_active_org_id
6. Single org: If user belongs to exactly one org, use it
7. Error: No org context — return 403 or prompt org selection
```

### TenantContext Type

```typescript
/**
 * Immutable tenant context — created once per request, passed through
 * the entire call chain. Never mutated after creation.
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
  readonly resolvedVia:
    | 'header'
    | 'session'
    | 'url'
    | 'project_config'
    | 'user_default'
    | 'single_org';
  /** Organisation plan (affects feature gates) */
  readonly plan: OrgPlan;
}

export type OrgRole = 'owner' | 'admin' | 'member' | 'viewer';
export type OrgPlan = 'free' | 'pro' | 'enterprise';
```

### Middleware Flow

```text
Request
  │
  ▼
[Auth Middleware] ─── Verify JWT/session → userId
  │
  ▼
[Tenant Middleware] ─── Resolve org context → TenantContext
  │                     Set RLS variables (app.current_org_id, app.current_user_id)
  │                     Verify membership (user belongs to org)
  │                     Attach TenantContext to request
  │
  ▼
[Route Handler] ─── Access ctx.tenant.orgId for queries
  │                  All queries automatically filtered by RLS
  │
  ▼
[Audit Middleware] ─── Log mutation with orgId, userId, action
```

### Org Switching

When a user switches organisations (t004.3):

1. Verify user has membership in target org
2. Update `users.last_active_org_id` to new org
3. Issue new session token with updated `org_id` claim
4. Clear any org-specific caches (AI context, memory namespace)
5. Redirect to org-scoped URL (`/org/:slug/dashboard`)

### Worker/Headless Context

For autonomous workers (supervisor dispatch), tenant context is set via:

```bash
# In worker dispatch prompt or environment
X-Org-Id: <org-uuid>

# Or in credential-helper resolution
credential-helper.sh export --tenant <org-slug>
```

The worker's entire session operates within that org's data boundary.
AI memories stored during the session are tagged with the org's namespace.

### Cross-Org Operations (Superadmin)

Superadmin operations bypass RLS by using the database superuser role:

```typescript
// Superadmin context — no RLS filtering
const superadminDb = drizzle(superuserPool);

// List all orgs
const allOrgs = await superadminDb.select().from(organisations);

// Cross-org aggregation
const orgStats = await superadminDb
  .select({
    orgId: ai_sessions.orgId,
    sessionCount: count(ai_sessions.id),
  })
  .from(ai_sessions)
  .groupBy(ai_sessions.orgId);
```

## Integration with Existing Multi-Tenant Credentials

The existing `credential-helper.sh` tenant system maps to this schema:

| Existing concept | New schema equivalent |
|-----------------|----------------------|
| Tenant name (e.g., `client-acme`) | `organisations.slug` |
| `~/.config/aidevops/tenants/{name}/` | `org_credentials` table rows |
| `active-tenant` file | `users.last_active_org_id` |
| `.aidevops-tenant` project file | Project-level org binding (unchanged) |
| `credential-helper.sh switch` | Org switch (update session + last_active) |

The file-based credential system continues to work for CLI/local development.
The database schema adds server-side isolation for hosted/multi-user deployments.

## Migration Path

### Phase 1: Schema Only (this task, t004.1)

- Define schema types and design document
- No runtime changes — existing credential-helper continues to work

### Phase 2: Middleware (t004.2)

- Implement tenant middleware and scoped query helpers
- Add RLS policies to database migrations

### Phase 3: UI (t004.3)

- Org switcher component
- Session context management

### Phase 4: AI Isolation (t004.4)

- Namespace AI sessions, memories, patterns per org
- Ensure worker dispatch carries org context

### Phase 5: Tests (t004.5)

- Cross-org boundary tests
- RLS enforcement verification
- Org switching integration tests

## TypeScript Types

### OrgSettings

```typescript
export interface OrgSettings {
  /** Default AI model tier for this org */
  defaultModelTier?: 'haiku' | 'sonnet' | 'opus';
  /** Daily budget cap in USD (token-billed providers) */
  dailyBudgetUsd?: number;
  /** Allowed model providers */
  allowedProviders?: string[];
  /** Feature flags */
  features?: Record<string, boolean>;
  /** Custom branding */
  branding?: {
    primaryColor?: string;
    logoUrl?: string;
  };
}
```

### SessionContext

```typescript
export interface SessionContext {
  /** Active model for this session */
  model?: string;
  /** Session-specific memory namespace */
  memoryNamespace?: string;
  /** Accumulated token usage */
  tokenUsage?: {
    input: number;
    output: number;
  };
  /** Session metadata */
  metadata?: Record<string, unknown>;
}
```
