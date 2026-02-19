/**
 * Multi-Org Data Isolation Schema
 *
 * Task: t004.1 — Design multi-org data isolation schema and tenant context model
 *
 * This schema defines the database tables for multi-organisation support.
 * Uses row-level tenancy with PostgreSQL RLS for enforcement.
 *
 * Isolation strategy: shared database, shared schema, org_id column on all
 * tenant-scoped tables. RLS policies enforce isolation at the DB level.
 *
 * Related tasks:
 * - t004.2: Tenant-scoped queries and middleware
 * - t004.3: Org-switching UI and session context
 * - t004.4: AI context isolation per organisation
 * - t004.5: Integration tests for data boundaries
 */

import {
  pgTable,
  pgEnum,
  uuid,
  text,
  varchar,
  integer,
  boolean,
  timestamp,
  jsonb,
  index,
  uniqueIndex,
} from 'drizzle-orm/pg-core';
import { relations, sql } from 'drizzle-orm';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

export const orgRoleEnum = pgEnum('org_role', [
  'owner',
  'admin',
  'member',
  'viewer',
]);

// ---------------------------------------------------------------------------
// Reusable column patterns
// ---------------------------------------------------------------------------

const timestamps = {
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .defaultNow()
    .$onUpdate(() => new Date()),
};

// ---------------------------------------------------------------------------
// Global tables (no org_id)
// ---------------------------------------------------------------------------

/**
 * Organisations — the root tenant entity.
 * Every org-scoped record references this table via org_id.
 */
export const organisations = pgTable('organisations', {
  id: uuid('id').primaryKey().defaultRandom(),
  slug: varchar('slug', { length: 63 }).notNull().unique(),
  name: text('name').notNull(),
  plan: text('plan', { enum: ['free', 'pro', 'enterprise'] })
    .notNull()
    .default('free'),
  settings: jsonb('settings').$type<OrgSettings>().default({}),
  ...timestamps,
});

/**
 * Users — global, exist independently of organisations.
 * A user can belong to multiple organisations via org_memberships.
 */
export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  email: varchar('email', { length: 255 }).notNull().unique(),
  name: text('name'),
  avatarUrl: text('avatar_url'),
  lastActiveOrgId: uuid('last_active_org_id').references(
    () => organisations.id,
    { onDelete: 'set null' },
  ),
  ...timestamps,
});

/**
 * Org memberships — join table between users and organisations.
 * This is the authorisation boundary: role determines permissions.
 */
export const orgMemberships = pgTable(
  'org_memberships',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organisations.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    role: orgRoleEnum('role').notNull().default('member'),
    invitedBy: uuid('invited_by').references(() => users.id, {
      onDelete: 'set null',
    }),
    joinedAt: timestamp('joined_at', { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    uniqueIndex('org_memberships_org_user_idx').on(table.orgId, table.userId),
    index('org_memberships_user_idx').on(table.userId),
  ],
);

// ---------------------------------------------------------------------------
// Org-scoped tables (require org_id NOT NULL)
// ---------------------------------------------------------------------------

/**
 * Org credentials — encrypted API keys and secrets per organisation.
 * Maps to the existing credential-helper.sh tenant concept.
 */
export const orgCredentials = pgTable(
  'org_credentials',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organisations.id, { onDelete: 'cascade' }),
    service: varchar('service', { length: 100 }).notNull(),
    keyName: varchar('key_name', { length: 100 }).notNull(),
    encryptedValue: text('encrypted_value').notNull(),
    createdBy: uuid('created_by').references(() => users.id, {
      onDelete: 'set null',
    }),
    ...timestamps,
  },
  (table) => [
    uniqueIndex('org_credentials_org_service_key_idx').on(
      table.orgId,
      table.service,
      table.keyName,
    ),
    index('org_credentials_org_idx').on(table.orgId),
  ],
);

/**
 * AI sessions — strictly org-scoped.
 * Each session operates within a single org's data boundary.
 * Critical for t004.4 (AI context isolation).
 */
export const aiSessions = pgTable(
  'ai_sessions',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organisations.id, { onDelete: 'cascade' }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    model: varchar('model', { length: 100 }),
    context: jsonb('context').$type<SessionContext>().default({}),
    startedAt: timestamp('started_at', { withTimezone: true })
      .notNull()
      .defaultNow(),
    endedAt: timestamp('ended_at', { withTimezone: true }),
  },
  (table) => [
    index('ai_sessions_org_idx').on(table.orgId),
    index('ai_sessions_user_idx').on(table.userId),
    index('ai_sessions_org_user_idx').on(table.orgId, table.userId),
  ],
);

/**
 * Memories — can be global (personal) or org-scoped (shared within org).
 * org_id is nullable: NULL = personal memory, non-NULL = org memory.
 */
export const memories = pgTable(
  'memories',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    orgId: uuid('org_id').references(() => organisations.id, {
      onDelete: 'cascade',
    }),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    content: text('content').notNull(),
    confidence: text('confidence', { enum: ['low', 'medium', 'high'] })
      .notNull()
      .default('medium'),
    namespace: varchar('namespace', { length: 100 }),
    accessCount: integer('access_count').notNull().default(0),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    index('memories_org_idx').on(table.orgId),
    index('memories_user_idx').on(table.userId),
    index('memories_org_scoped_idx')
      .on(table.orgId, table.userId)
      .where(sql`org_id IS NOT NULL`),
  ],
);

/**
 * Audit log — all org-scoped mutations are logged.
 * Append-only for compliance and debugging.
 */
export const auditLog = pgTable(
  'audit_log',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    orgId: uuid('org_id')
      .notNull()
      .references(() => organisations.id, { onDelete: 'cascade' }),
    userId: uuid('user_id').references(() => users.id, {
      onDelete: 'set null',
    }),
    action: varchar('action', { length: 100 }).notNull(),
    entityType: varchar('entity_type', { length: 100 }).notNull(),
    entityId: uuid('entity_id'),
    metadata: jsonb('metadata')
      .$type<Record<string, unknown>>()
      .default({}),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    index('audit_log_org_idx').on(table.orgId),
    index('audit_log_org_action_idx').on(table.orgId, table.action),
    index('audit_log_created_idx').on(table.createdAt),
  ],
);

// ---------------------------------------------------------------------------
// Relations (for Drizzle relational queries)
// ---------------------------------------------------------------------------

export const organisationsRelations = relations(organisations, ({ many }) => ({
  memberships: many(orgMemberships),
  credentials: many(orgCredentials),
  aiSessions: many(aiSessions),
  memories: many(memories),
  auditLog: many(auditLog),
}));

export const usersRelations = relations(users, ({ one, many }) => ({
  lastActiveOrg: one(organisations, {
    fields: [users.lastActiveOrgId],
    references: [organisations.id],
  }),
  memberships: many(orgMemberships),
  aiSessions: many(aiSessions),
  memories: many(memories),
}));

export const orgMembershipsRelations = relations(
  orgMemberships,
  ({ one }) => ({
    organisation: one(organisations, {
      fields: [orgMemberships.orgId],
      references: [organisations.id],
    }),
    user: one(users, {
      fields: [orgMemberships.userId],
      references: [users.id],
    }),
    inviter: one(users, {
      fields: [orgMemberships.invitedBy],
      references: [users.id],
    }),
  }),
);

export const orgCredentialsRelations = relations(orgCredentials, ({ one }) => ({
  organisation: one(organisations, {
    fields: [orgCredentials.orgId],
    references: [organisations.id],
  }),
  creator: one(users, {
    fields: [orgCredentials.createdBy],
    references: [users.id],
  }),
}));

export const aiSessionsRelations = relations(aiSessions, ({ one }) => ({
  organisation: one(organisations, {
    fields: [aiSessions.orgId],
    references: [organisations.id],
  }),
  user: one(users, {
    fields: [aiSessions.userId],
    references: [users.id],
  }),
}));

export const memoriesRelations = relations(memories, ({ one }) => ({
  organisation: one(organisations, {
    fields: [memories.orgId],
    references: [organisations.id],
  }),
  user: one(users, {
    fields: [memories.userId],
    references: [users.id],
  }),
}));

export const auditLogRelations = relations(auditLog, ({ one }) => ({
  organisation: one(organisations, {
    fields: [auditLog.orgId],
    references: [organisations.id],
  }),
  user: one(users, {
    fields: [auditLog.userId],
    references: [users.id],
  }),
}));

// ---------------------------------------------------------------------------
// TypeScript types
// ---------------------------------------------------------------------------

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
