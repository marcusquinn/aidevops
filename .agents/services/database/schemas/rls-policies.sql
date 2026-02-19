-- Multi-Org Row-Level Security Policies
--
-- Task: t004.1 — Design multi-org data isolation schema and tenant context model
--
-- These policies enforce data isolation at the PostgreSQL level.
-- Even if application code has a bug, RLS prevents cross-org data leaks.
--
-- Prerequisites:
-- 1. Tables created from multi-org.ts schema
-- 2. Application connects as 'app_user' role (not superuser)
-- 3. Middleware sets app.current_org_id and app.current_user_id per request
--
-- Usage:
-- Run this after table creation. The tenant middleware (t004.2) sets
-- the session variables before each request.

-- ---------------------------------------------------------------------------
-- Application role
-- ---------------------------------------------------------------------------

-- Create the application role if it doesn't exist.
-- The app connects as this role; superuser bypasses RLS.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user;
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Enable RLS on all org-scoped tables
-- ---------------------------------------------------------------------------

ALTER TABLE org_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE memories ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

-- Force RLS even for table owners (prevents accidental bypass)
ALTER TABLE org_credentials FORCE ROW LEVEL SECURITY;
ALTER TABLE ai_sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE memories FORCE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- Org-scoped policies (strict: org_id must match current_org_id)
-- ---------------------------------------------------------------------------

-- org_credentials: users can only access credentials for their current org
CREATE POLICY org_isolation_credentials ON org_credentials
  FOR ALL
  TO app_user
  USING (org_id = current_setting('app.current_org_id', true)::uuid)
  WITH CHECK (org_id = current_setting('app.current_org_id', true)::uuid);

-- ai_sessions: users can only access sessions for their current org
CREATE POLICY org_isolation_ai_sessions ON ai_sessions
  FOR ALL
  TO app_user
  USING (org_id = current_setting('app.current_org_id', true)::uuid)
  WITH CHECK (org_id = current_setting('app.current_org_id', true)::uuid);

-- audit_log: users can only read audit entries for their current org
-- Write is allowed (for logging) but read is org-scoped
CREATE POLICY org_isolation_audit_log ON audit_log
  FOR SELECT
  TO app_user
  USING (org_id = current_setting('app.current_org_id', true)::uuid);

-- audit_log: allow inserts for current org only
CREATE POLICY org_insert_audit_log ON audit_log
  FOR INSERT
  TO app_user
  WITH CHECK (org_id = current_setting('app.current_org_id', true)::uuid);

-- ---------------------------------------------------------------------------
-- Org-optional policies (memories: org-scoped OR personal)
-- ---------------------------------------------------------------------------

-- memories: can see org memories (if in current org) OR personal memories
-- Personal memories have org_id IS NULL and belong to the current user
CREATE POLICY org_or_personal_memories ON memories
  FOR ALL
  TO app_user
  USING (
    org_id = current_setting('app.current_org_id', true)::uuid
    OR (
      org_id IS NULL
      AND user_id = current_setting('app.current_user_id', true)::uuid
    )
  )
  WITH CHECK (
    org_id = current_setting('app.current_org_id', true)::uuid
    OR (
      org_id IS NULL
      AND user_id = current_setting('app.current_user_id', true)::uuid
    )
  );

-- ---------------------------------------------------------------------------
-- Grant permissions to app_user
-- ---------------------------------------------------------------------------

-- Global tables: read access (memberships checked in application layer)
GRANT SELECT ON organisations TO app_user;
GRANT SELECT ON users TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON org_memberships TO app_user;

-- Org-scoped tables: full CRUD (RLS handles isolation)
GRANT SELECT, INSERT, UPDATE, DELETE ON org_credentials TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ai_sessions TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON memories TO app_user;
GRANT SELECT, INSERT ON audit_log TO app_user;

-- Users can update their own profile
GRANT UPDATE (name, avatar_url, last_active_org_id) ON users TO app_user;

-- ---------------------------------------------------------------------------
-- Helper function: verify org membership
-- ---------------------------------------------------------------------------

-- Used by application code to verify a user belongs to an org
-- before setting the RLS context. This runs as superuser (definer).
CREATE OR REPLACE FUNCTION verify_org_membership(
  p_user_id uuid,
  p_org_id uuid
) RETURNS TABLE(role text, org_slug varchar, org_plan text) AS $$
BEGIN
  RETURN QUERY
  SELECT
    m.role::text,
    o.slug,
    o.plan
  FROM org_memberships m
  JOIN organisations o ON o.id = m.org_id
  WHERE m.user_id = p_user_id
    AND m.org_id = p_org_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- ---------------------------------------------------------------------------
-- Helper function: get user's organisations
-- ---------------------------------------------------------------------------

-- Returns all organisations a user belongs to (for org switcher UI, t004.3)
CREATE OR REPLACE FUNCTION get_user_organisations(
  p_user_id uuid
) RETURNS TABLE(
  org_id uuid,
  org_slug varchar,
  org_name text,
  org_plan text,
  user_role text,
  joined_at timestamptz
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    o.id,
    o.slug,
    o.name,
    o.plan,
    m.role::text,
    m.joined_at
  FROM org_memberships m
  JOIN organisations o ON o.id = m.org_id
  WHERE m.user_id = p_user_id
  ORDER BY m.joined_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
