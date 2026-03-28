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
- **Context resolution**: Request header > session > URL path > project config > user default > single org > 403

**Sibling tasks**: t004.2 (middleware), t004.3 (org-switching UI), t004.4 (AI context isolation), t004.5 (integration tests)

<!-- AI-CONTEXT-END -->

## Architecture Overview

Row-level tenancy (shared database, shared schema, `org_id` column) — orgs share the same feature set, superadmin needs cross-org visibility, single migration path, PostgreSQL RLS enforces at DB level.

| Strategy | Pros | Cons | When to use |
|----------|------|------|-------------|
| **Row-level** (chosen) | Simple ops, easy cross-org queries for superadmin, single migration path | Requires discipline on every query | <1000 orgs, shared infrastructure |
| Schema-per-tenant | Strong isolation, easy per-tenant backup | Migration complexity, connection pooling | Regulated industries |
| Database-per-tenant | Strongest isolation | Operational nightmare at scale | Enterprise with dedicated infra |

### Data Classification

| Category | `org_id` column | RLS policy | Examples |
|----------|----------------|------------|---------|
| **Org-scoped** | Required, NOT NULL | Enforced | credentials, projects, ai_sessions, api_keys |
| **Org-optional** | Nullable | Conditional | memories, patterns (can be global or org-specific) |
| **Global** | None | None | organisations, users, system_config |

## Schema

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

Full definitions in `schemas/multi-org.ts`. Key design notes:

- `organisations`: `slug` (varchar 63) is URL-safe, used in routing; `plan` enum: `free|pro|enterprise`
- `users`: global — can belong to multiple orgs; no password field (auth delegated); `lastActiveOrgId` nullable
- `org_memberships`: unique index on `(orgId, userId)`; roles: `owner|admin|member|viewer`

### Org-Scoped Tables Pattern

All tenant-scoped tables spread `orgScoped`:

```typescript
const orgScoped = {
  orgId: uuid('org_id').notNull().references(() => organisations.id, { onDelete: 'cascade' }),
};
```

Table-specific notes:

- `org_credentials`: unique index on `(orgId, service, keyName)`; `encryptedValue` never stored in plaintext
- `ai_sessions` — t004.4: composite org+user index for session scoping
- `memories`: nullable `org_id` = personal; conditional index `where(sql\`org_id IS NOT NULL\`)`
- `audit_log`: `org_id` NOT NULL; indexed on `(org_id, action)` and `created_at`

## Row-Level Security (RLS)

PostgreSQL RLS enforces isolation at the database level — safety net even if application code has a bug.

```sql
ALTER TABLE org_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE memories ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

CREATE ROLE app_user;

-- Standard org isolation (org_credentials, ai_sessions, audit_log)
CREATE POLICY org_isolation ON org_credentials FOR ALL TO app_user
  USING (org_id = current_setting('app.current_org_id')::uuid);
CREATE POLICY org_isolation ON ai_sessions FOR ALL TO app_user
  USING (org_id = current_setting('app.current_org_id')::uuid);
CREATE POLICY org_isolation ON audit_log FOR ALL TO app_user
  USING (org_id = current_setting('app.current_org_id')::uuid);

-- Memories: org-scoped OR personal (org_id IS NULL and user owns it)
CREATE POLICY org_or_personal ON memories FOR ALL TO app_user
  USING (
    org_id = current_setting('app.current_org_id')::uuid
    OR (org_id IS NULL AND user_id = current_setting('app.current_user_id')::uuid)
  );
```

### Setting Context Per Request

```typescript
// In middleware (before any query) — `true` = local to transaction only
await db.execute(sql`SELECT set_config('app.current_org_id', ${orgId}, true)`);
await db.execute(sql`SELECT set_config('app.current_user_id', ${userId}, true)`);
```

## Tenant Context Model

### TenantContext Type

```typescript
export interface TenantContext {
  readonly orgId: string;       // UUID — used for all DB queries
  readonly orgSlug: string;     // URL routing, display
  readonly userId: string;      // Authenticated user
  readonly role: OrgRole;       // User's role in this org
  readonly resolvedVia: 'header' | 'session' | 'url' | 'project_config' | 'user_default' | 'single_org';
  readonly plan: OrgPlan;       // Affects feature gates
}

export type OrgRole = 'owner' | 'admin' | 'member' | 'viewer';
export type OrgPlan = 'free' | 'pro' | 'enterprise';
```

### Middleware Flow

```text
[Auth Middleware]   → verify JWT/session → userId
[Tenant Middleware] → resolve org context (header > session > URL > project_config > user_default > single_org)
                    → set RLS vars (app.current_org_id, app.current_user_id)
                    → verify membership → attach TenantContext to request
[Route Handler]     → ctx.tenant.orgId (all queries filtered by RLS)
[Audit Middleware]  → log mutation with orgId, userId, action
```

### Org Switching (t004.3)

1. Verify user has membership in target org
2. Update `users.last_active_org_id`
3. Issue new session token with updated `org_id` claim
4. Clear org-specific caches (AI context, memory namespace)
5. Redirect to `/org/:slug/dashboard`

### Worker/Headless Context

Pass `X-Org-Id: <org-uuid>` header, or resolve via `credential-helper.sh export --tenant <org-slug>`.

### Cross-Org Operations (Superadmin)

```typescript
// Superadmin context — no RLS filtering (uses database superuser role)
const superadminDb = drizzle(superuserPool);
const allOrgs = await superadminDb.select().from(organisations);
```

## Credential System Integration

File-based credential system continues for CLI/local development. Database schema adds server-side isolation for hosted/multi-user deployments.

| Existing concept | New schema equivalent |
|-----------------|----------------------|
| Tenant name (e.g., `client-acme`) | `organisations.slug` |
| `~/.config/aidevops/tenants/{name}/` | `org_credentials` table rows |
| `active-tenant` file | `users.last_active_org_id` |
| `.aidevops-tenant` project file | Project-level org binding (unchanged) |
| `credential-helper.sh switch` | Org switch (update session + last_active) |

## Migration Path

| Phase | Task | Scope |
|-------|------|-------|
| 1 | t004.1 (this) | Schema types and design — no runtime changes |
| 2 | t004.2 | Tenant middleware, scoped query helpers, RLS policies |
| 3 | t004.3 | Org switcher component, session context management |
| 4 | t004.4 | Namespace AI sessions, memories, patterns per org |
| 5 | t004.5 | Cross-org boundary tests, RLS verification, org switching integration tests |

## Related

- **Vector search per-tenant isolation**: `tools/database/vector-search.md`
- **PGlite local-first**: `tools/database/pglite-local-first.md`
- **Postgres + Drizzle**: `services/database/postgres-drizzle-skill.md`
