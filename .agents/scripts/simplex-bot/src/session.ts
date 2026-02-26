/**
 * SimpleX Bot — Session Store
 *
 * SQLite-backed session store using bun:sqlite for per-contact/group
 * session isolation. Tracks conversation state, last activity, and
 * metadata for each chat context.
 *
 * Reference: t1327.4 bot framework specification
 */

import { Database } from "bun:sqlite";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { homedir } from "node:os";

/** Default data directory for bot state */
const DEFAULT_DATA_DIR = resolve(
  homedir(),
  ".aidevops/.agent-workspace/simplex-bot",
);

/** Session record stored in SQLite */
export interface Session {
  /** Unique session ID (format: "contact:<id>" or "group:<id>") */
  id: string;
  /** Chat type: "direct" or "group" */
  chatType: "direct" | "group";
  /** Contact or group ID from SimpleX */
  chatId: number;
  /** Display name of the contact or group */
  displayName: string;
  /** ISO timestamp of session creation */
  createdAt: string;
  /** ISO timestamp of last activity */
  lastActivity: string;
  /** Number of messages processed in this session */
  messageCount: number;
  /** JSON-encoded metadata (extensible) */
  metadata: string;
}

/** Session metadata (parsed from JSON) */
export interface SessionMetadata {
  /** Whether this is a business address chat */
  businessChat?: boolean;
  /** Whether the contact has been approved (pairing) */
  approved?: boolean;
  /** Custom tags for this session */
  tags?: string[];
  /** Last command executed */
  lastCommand?: string;
}

/** SQLite-backed session store */
export class SessionStore {
  private db: Database;

  /** Create a session store, initializing the database if needed */
  constructor(dataDir?: string) {
    const dir = dataDir ?? DEFAULT_DATA_DIR;
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }

    const dbPath = resolve(dir, "sessions.db");
    this.db = new Database(dbPath);

    // Enable WAL mode for concurrent reads (matches mail-helper.sh pattern)
    this.db.exec("PRAGMA journal_mode=WAL");
    this.db.exec("PRAGMA busy_timeout=5000");

    this.initSchema();
  }

  /** Create the sessions table if it doesn't exist */
  private initSchema(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        chat_type TEXT NOT NULL,
        chat_id INTEGER NOT NULL,
        display_name TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        last_activity TEXT NOT NULL DEFAULT (datetime('now')),
        message_count INTEGER NOT NULL DEFAULT 0,
        metadata TEXT NOT NULL DEFAULT '{}'
      )
    `);

    this.db.exec(`
      CREATE INDEX IF NOT EXISTS idx_sessions_chat_id
        ON sessions(chat_type, chat_id)
    `);

    this.db.exec(`
      CREATE INDEX IF NOT EXISTS idx_sessions_last_activity
        ON sessions(last_activity)
    `);
  }

  /** Get or create a session for a contact */
  getContactSession(contactId: number, displayName?: string): Session {
    return this.getOrCreate("direct", contactId, displayName ?? "");
  }

  /** Get or create a session for a group */
  getGroupSession(groupId: number, displayName?: string): Session {
    return this.getOrCreate("group", groupId, displayName ?? "");
  }

  /** Get or create a session by chat type and ID */
  private getOrCreate(
    chatType: "direct" | "group",
    chatId: number,
    displayName: string,
  ): Session {
    const id = `${chatType}:${chatId}`;

    const existing = this.db
      .query<Session, [string]>("SELECT * FROM sessions WHERE id = ?")
      .get(id);

    if (existing) {
      // Update last activity
      this.db
        .query("UPDATE sessions SET last_activity = datetime('now') WHERE id = ?")
        .run(id);
      return existing;
    }

    // Create new session
    this.db
      .query(
        `INSERT INTO sessions (id, chat_type, chat_id, display_name, created_at, last_activity, message_count, metadata)
         VALUES (?, ?, ?, ?, datetime('now'), datetime('now'), 0, '{}')`,
      )
      .run(id, chatType, chatId, displayName);

    return this.db
      .query<Session, [string]>("SELECT * FROM sessions WHERE id = ?")
      .get(id)!;
  }

  /** Increment the message count for a session */
  recordMessage(sessionId: string): void {
    this.db
      .query(
        `UPDATE sessions
         SET message_count = message_count + 1,
             last_activity = datetime('now')
         WHERE id = ?`,
      )
      .run(sessionId);
  }

  /** Update session metadata (merges with existing) */
  updateMetadata(sessionId: string, updates: Partial<SessionMetadata>): void {
    const existing = this.db
      .query<{ metadata: string }, [string]>(
        "SELECT metadata FROM sessions WHERE id = ?",
      )
      .get(sessionId);

    if (!existing) {
      return;
    }

    let current: SessionMetadata;
    try {
      current = JSON.parse(existing.metadata) as SessionMetadata;
    } catch {
      current = {};
    }

    const merged = { ...current, ...updates };
    this.db
      .query("UPDATE sessions SET metadata = ? WHERE id = ?")
      .run(JSON.stringify(merged), sessionId);
  }

  /** Get session metadata */
  getMetadata(sessionId: string): SessionMetadata {
    const row = this.db
      .query<{ metadata: string }, [string]>(
        "SELECT metadata FROM sessions WHERE id = ?",
      )
      .get(sessionId);

    if (!row) {
      return {};
    }

    try {
      return JSON.parse(row.metadata) as SessionMetadata;
    } catch {
      return {};
    }
  }

  /** List all active sessions (ordered by last activity) */
  listSessions(limit = 50): Session[] {
    return this.db
      .query<Session, [number]>(
        "SELECT * FROM sessions ORDER BY last_activity DESC LIMIT ?",
      )
      .all(limit);
  }

  /** Delete sessions idle for more than the given number of seconds */
  cleanupIdle(idleSeconds: number): number {
    const result = this.db
      .query(
        `DELETE FROM sessions
         WHERE last_activity < datetime('now', '-' || ? || ' seconds')`,
      )
      .run(idleSeconds);

    return result.changes;
  }

  /** Delete a specific session */
  deleteSession(sessionId: string): boolean {
    const result = this.db
      .query("DELETE FROM sessions WHERE id = ?")
      .run(sessionId);

    return result.changes > 0;
  }

  /** Get total session count */
  count(): number {
    const row = this.db
      .query<{ count: number }, []>("SELECT COUNT(*) as count FROM sessions")
      .get();

    return row?.count ?? 0;
  }

  /** Close the database connection */
  close(): void {
    this.db.close();
  }
}
