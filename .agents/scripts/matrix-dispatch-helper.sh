#!/usr/bin/env bash
# matrix-dispatch-helper.sh - Matrix bot for dispatching messages to AI runners
#
# Bridges Matrix chat rooms to aidevops runners via OpenCode server.
# Each Matrix room maps to a named runner. Messages in the room become
# prompts dispatched to the runner, with responses posted back.
#
# Usage:
#   matrix-dispatch-helper.sh setup [--dry-run]        # Interactive setup wizard
#   matrix-dispatch-helper.sh start [--daemon]         # Start the bot
#   matrix-dispatch-helper.sh stop                     # Stop the bot
#   matrix-dispatch-helper.sh status                   # Show bot status
#   matrix-dispatch-helper.sh map <room> <runner>      # Map room to runner
#   matrix-dispatch-helper.sh unmap <room>             # Remove room mapping
#   matrix-dispatch-helper.sh mappings                 # List room-to-runner mappings
#   matrix-dispatch-helper.sh test <room> "message"    # Test dispatch without Matrix
#   matrix-dispatch-helper.sh logs [--tail N] [--follow]
#   matrix-dispatch-helper.sh help
#
# Requirements:
#   - Node.js >= 18 (for matrix-bot-sdk)
#   - jq (brew install jq)
#   - OpenCode server running (opencode serve)
#   - Matrix homeserver with bot account
#
# Configuration:
#   ~/.config/aidevops/matrix-bot.json
#
# Security:
#   - Bot access token stored in matrix-bot.json (600 permissions)
#   - Uses HTTPS for remote Matrix homeservers
#   - Room-to-runner mapping prevents unauthorized dispatch
#   - Only responds to messages from allowed users (configurable)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aidevops"
readonly CONFIG_FILE="$CONFIG_DIR/matrix-bot.json"
readonly DATA_DIR="$HOME/.aidevops/.agent-workspace/matrix-bot"
readonly LOG_DIR="$DATA_DIR/logs"
readonly PID_FILE="$DATA_DIR/bot.pid"
readonly BOT_SCRIPT="$DATA_DIR/bot.mjs"
readonly SESSION_STORE_SCRIPT="$DATA_DIR/session-store.mjs"
readonly SESSION_DB="$DATA_DIR/sessions.db"
readonly ENTITY_HELPER="$HOME/.aidevops/agents/scripts/entity-helper.sh"
readonly MEMORY_DB="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}/memory.db"
readonly RUNNER_HELPER="$HOME/.aidevops/agents/scripts/runner-helper.sh"
readonly OPENCODE_PORT="${OPENCODE_PORT:-4096}"
readonly OPENCODE_HOST="${OPENCODE_HOST:-127.0.0.1}"

readonly BOLD='\033[1m'

# Logging: uses shared log_* from shared-constants.sh with MATRIX prefix
# shellcheck disable=SC2034  # Used by shared-constants.sh log_* functions
LOG_PREFIX="MATRIX"

#######################################
# Check dependencies
#######################################
check_deps() {
	local missing=()

	if ! command -v node &>/dev/null; then
		missing+=("node (Node.js >= 18)")
	fi

	if ! command -v jq &>/dev/null; then
		missing+=("jq")
	fi

	if ((${#missing[@]} > 0)); then
		log_error "Missing dependencies:"
		for dep in "${missing[@]}"; do
			echo "  - $dep"
		done
		return 1
	fi

	return 0
}

#######################################
# Ensure config directory exists
#######################################
ensure_dirs() {
	mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
	chmod 700 "$CONFIG_DIR"
}

#######################################
# Check if config exists
#######################################
config_exists() {
	[[ -f "$CONFIG_FILE" ]]
}

#######################################
# Read config value
#######################################
config_get() {
	local key="$1"
	jq -r --arg key "$key" '.[$key] // empty' "$CONFIG_FILE" 2>/dev/null
}

#######################################
# Write config value
#######################################
config_set() {
	local key="$1"
	local value="$2"

	if [[ ! -f "$CONFIG_FILE" ]]; then
		echo '{}' >"$CONFIG_FILE"
		chmod 600 "$CONFIG_FILE"
	fi

	local temp_file
	temp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${temp_file}'"
	jq --arg key "$key" --arg value "$value" '.[$key] = $value' "$CONFIG_FILE" >"$temp_file" && mv "$temp_file" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE"
}

#######################################
# Determine protocol based on host
#######################################
get_protocol() {
	local host="$1"
	if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
		echo "http"
	else
		echo "https"
	fi
}

#######################################
# Check if OpenCode server is running
#######################################
check_opencode_server() {
	local protocol
	protocol=$(get_protocol "$OPENCODE_HOST")
	local url="${protocol}://${OPENCODE_HOST}:${OPENCODE_PORT}/global/health"

	if curl -sf "$url" &>/dev/null; then
		return 0
	else
		return 1
	fi
}

#######################################
# Interactive setup wizard
#######################################
cmd_setup() {
	local dry_run=false
	if [[ "${1:-}" == "--dry-run" ]]; then
		dry_run=true
		shift
	fi

	check_deps || return 1
	ensure_dirs

	echo -e "${BOLD}Matrix Bot Setup${NC}"
	if [[ "$dry_run" == "true" ]]; then
		echo -e "${YELLOW}[DRY RUN MODE - No changes will be saved]${NC}"
	fi
	echo "──────────────────────────────────"
	echo ""
	echo "This wizard configures a Matrix bot that dispatches messages to AI runners."
	echo ""

	# Homeserver URL
	local homeserver
	if config_exists; then
		local existing_hs
		existing_hs=$(config_get "homeserverUrl")
		if [[ -n "$existing_hs" ]]; then
			echo -n "Matrix homeserver URL [$existing_hs]: "
			read -r homeserver
			homeserver="${homeserver:-$existing_hs}"
		else
			echo -n "Matrix homeserver URL (e.g., https://matrix.example.com): "
			read -r homeserver
		fi
	else
		echo -n "Matrix homeserver URL (e.g., https://matrix.example.com): "
		read -r homeserver
	fi

	if [[ -z "$homeserver" ]]; then
		log_error "Homeserver URL is required"
		return 1
	fi

	# Access token
	echo ""
	echo "Create a bot account on your Matrix server, then get an access token."
	echo "For Synapse: use the admin API or register via Element and extract token."
	echo "For Cloudron Synapse: Admin Console > Users > Create user, then login via Element."
	echo ""

	local access_token
	local existing_token
	existing_token=$(config_get "accessToken")
	if [[ -n "$existing_token" ]]; then
		echo -n "Bot access token [****${existing_token: -8}]: "
		read -r access_token
		access_token="${access_token:-$existing_token}"
	else
		echo -n "Bot access token: "
		read -rs access_token
		echo ""
	fi

	if [[ -z "$access_token" ]]; then
		log_error "Access token is required"
		return 1
	fi

	# Allowed users (optional)
	echo ""
	echo "Restrict which Matrix users can trigger the bot (comma-separated)."
	echo "Leave empty to allow all users in mapped rooms."
	echo "Example: @admin:example.com,@dev:example.com"
	echo ""

	local allowed_users
	local existing_users
	existing_users=$(config_get "allowedUsers")
	if [[ -n "$existing_users" ]]; then
		echo -n "Allowed users [$existing_users]: "
		read -r allowed_users
		allowed_users="${allowed_users:-$existing_users}"
	else
		echo -n "Allowed users (empty = all): "
		read -r allowed_users
	fi

	# Default runner
	echo ""
	echo "Default runner for rooms without explicit mapping."
	echo "Messages in unmapped rooms go to this runner (or are ignored if empty)."
	echo ""

	local default_runner
	local existing_runner
	existing_runner=$(config_get "defaultRunner")
	if [[ -n "$existing_runner" ]]; then
		echo -n "Default runner [$existing_runner]: "
		read -r default_runner
		default_runner="${default_runner:-$existing_runner}"
	else
		echo -n "Default runner (empty = ignore unmapped rooms): "
		read -r default_runner
	fi

	# Session idle timeout
	echo ""
	echo "Session idle timeout (seconds). After this period of inactivity,"
	echo "the bot compacts the conversation context and frees the session."
	echo "The compacted summary is used to prime the next session."
	echo ""

	local idle_timeout
	local existing_timeout
	existing_timeout=$(config_get "sessionIdleTimeout")
	if [[ -n "$existing_timeout" ]]; then
		echo -n "Session idle timeout [${existing_timeout}s]: "
		read -r idle_timeout
		idle_timeout="${idle_timeout:-$existing_timeout}"
	else
		echo -n "Session idle timeout [300]: "
		read -r idle_timeout
		idle_timeout="${idle_timeout:-300}"
	fi

	# Save config
	if [[ "$dry_run" == "true" ]]; then
		log_info "Dry-run: Would save configuration to $CONFIG_FILE"
		echo ""
		echo "Configuration preview:"
		jq -n \
			--arg homeserverUrl "$homeserver" \
			--arg accessToken "****${access_token: -8}" \
			--arg allowedUsers "$allowed_users" \
			--arg defaultRunner "$default_runner" \
			--argjson sessionIdleTimeout "$idle_timeout" \
			'{
				homeserverUrl: $homeserverUrl,
				accessToken: $accessToken,
				allowedUsers: $allowedUsers,
				defaultRunner: $defaultRunner,
				roomMappings: {},
				botPrefix: "!ai",
				ignoreOwnMessages: true,
				maxPromptLength: 3000,
				responseTimeout: 600,
				sessionIdleTimeout: $sessionIdleTimeout
			}'
		echo ""
	else
		local temp_file
		temp_file=$(mktemp)
		_save_cleanup_scope
		trap '_run_cleanups' RETURN
		push_cleanup "rm -f '${temp_file}'"
		jq -n \
			--arg homeserverUrl "$homeserver" \
			--arg accessToken "$access_token" \
			--arg allowedUsers "$allowed_users" \
			--arg defaultRunner "$default_runner" \
			--argjson sessionIdleTimeout "$idle_timeout" \
			'{
				homeserverUrl: $homeserverUrl,
				accessToken: $accessToken,
				allowedUsers: $allowedUsers,
				defaultRunner: $defaultRunner,
				roomMappings: (input.roomMappings // {}),
				botPrefix: "!ai",
				ignoreOwnMessages: true,
				maxPromptLength: 3000,
				responseTimeout: 600,
				sessionIdleTimeout: $sessionIdleTimeout
			}' --jsonargs < <(if [[ -f "$CONFIG_FILE" ]]; then cat "$CONFIG_FILE"; else echo '{}'; fi) >"$temp_file"
		mv "$temp_file" "$CONFIG_FILE"
		chmod 600 "$CONFIG_FILE"
	fi

	# Install matrix-bot-sdk and better-sqlite3 if needed
	local needs_install=false
	if [[ ! -d "$DATA_DIR/node_modules/matrix-bot-sdk" ]]; then
		needs_install=true
	fi
	if [[ ! -d "$DATA_DIR/node_modules/better-sqlite3" ]]; then
		needs_install=true
	fi

	if [[ "$needs_install" == "true" ]]; then
		if [[ "$dry_run" == "true" ]]; then
			log_info "Dry-run: Would install dependencies (matrix-bot-sdk, better-sqlite3)"
		else
			log_info "Installing dependencies (matrix-bot-sdk, better-sqlite3)..."
			npm install --prefix "$DATA_DIR" matrix-bot-sdk better-sqlite3 2>/dev/null || {
				log_error "Failed to install dependencies"
				echo "Install manually: npm install --prefix $DATA_DIR matrix-bot-sdk better-sqlite3"
				return 1
			}
			log_success "Dependencies installed"
		fi
	fi

	# Generate session store and bot scripts
	if [[ "$dry_run" == "true" ]]; then
		log_info "Dry-run: Would generate session store and bot scripts"
	else
		generate_session_store_script
		generate_bot_script
	fi

	echo ""
	if [[ "$dry_run" == "true" ]]; then
		log_success "Dry-run complete! No changes were made."
		echo ""
		echo "To apply these settings, run:"
		echo "  matrix-dispatch-helper.sh setup"
	else
		log_success "Setup complete!"
		echo ""
		echo "Next steps:"
		echo "  1. Map rooms to runners:"
		echo "     matrix-dispatch-helper.sh map '!roomid:server' my-runner"
		echo ""
		echo "  2. Start the bot:"
		echo "     matrix-dispatch-helper.sh start"
		echo ""
		echo "  3. In a mapped Matrix room, type:"
		echo "     !ai Review the auth module for security issues"
	fi

	return 0
}

#######################################
# Generate the session store module
#######################################
generate_session_store_script() {
	cat >"$SESSION_STORE_SCRIPT" <<'SESSIONSCRIPT'
// session-store.mjs - Entity-aware session store for Matrix bot
// Generated by matrix-dispatch-helper.sh
// Do not edit directly - regenerate with: matrix-dispatch-helper.sh setup
//
// Uses the shared memory.db entity tables (Layer 0/1) from entity-helper.sh
// instead of a separate per-room sessions.db. This enables:
// - Entity resolution: Matrix user IDs -> entity profiles
// - Cross-channel context: entity history from all channels
// - Privacy-aware context loading
// - Immutable interaction log (Layer 0)

import Database from "better-sqlite3";
import { mkdirSync, existsSync } from "fs";
import { dirname } from "path";
import { execFileSync } from "child_process";

const MEMORY_DIR = process.env.AIDEVOPS_MEMORY_DIR ||
    `${process.env.HOME}/.aidevops/.agent-workspace/memory`;
const MEMORY_DB_PATH = `${MEMORY_DIR}/memory.db`;
const ENTITY_HELPER = `${process.env.HOME}/.aidevops/agents/scripts/entity-helper.sh`;

// Legacy DB for migration
const LEGACY_DB_PATH = process.env.MATRIX_SESSION_DB ||
    `${process.env.HOME}/.aidevops/.agent-workspace/matrix-bot/sessions.db`;

let _db = null;

/**
 * Get or create the database connection.
 * Uses the shared memory.db with entity tables (created by entity-helper.sh).
 * Also creates Matrix-specific session tracking table for room state.
 */
function getDb() {
    if (_db) return _db;

    mkdirSync(dirname(MEMORY_DB_PATH), { recursive: true });

    // Ensure entity tables exist by running entity-helper.sh migrate
    if (existsSync(ENTITY_HELPER)) {
        try {
            execFileSync(ENTITY_HELPER, ["migrate"], {
                timeout: 10000,
                stdio: "pipe",
            });
        } catch {
            // Non-fatal — tables may already exist
        }
    }

    _db = new Database(MEMORY_DB_PATH);
    _db.pragma("journal_mode = WAL");
    _db.pragma("busy_timeout = 5000");

    // Matrix-specific session tracking (room state, not message storage)
    // Messages go to the shared interactions table via entity-helper.sh
    _db.exec(`
        CREATE TABLE IF NOT EXISTS matrix_room_sessions (
            room_id          TEXT PRIMARY KEY,
            session_id       TEXT DEFAULT '',
            entity_id        TEXT DEFAULT '',
            conversation_id  TEXT DEFAULT '',
            runner_name      TEXT DEFAULT '',
            message_count    INTEGER DEFAULT 0,
            created_at       TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            last_active      TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_matrix_room_sessions_active
            ON matrix_room_sessions(last_active);
    `);

    return _db;
}

/**
 * Resolve a Matrix user ID to an entity ID.
 * Uses entity-helper.sh suggest/create for identity resolution.
 * Returns { entityId, isNew, entityName }.
 */
export function resolveEntity(matrixUserId, displayName = "") {
    // Try entity-helper.sh suggest first (exact match on channel)
    try {
        const result = execFileSync(ENTITY_HELPER, [
            "suggest", "matrix", matrixUserId,
        ], { timeout: 5000, stdio: "pipe" }).toString().trim();

        // Parse JSON output for exact match
        if (result.includes("Exact match found:")) {
            const jsonStr = result.split("Exact match found:")[1].trim();
            const matches = JSON.parse(jsonStr);
            if (matches.length > 0) {
                return {
                    entityId: matches[0].id,
                    isNew: false,
                    entityName: matches[0].name,
                };
            }
        }
    } catch {
        // suggest failed or no match — create new entity
    }

    // No existing entity — create one
    const name = displayName || matrixUserId.replace(/^@/, "").split(":")[0];
    try {
        const entityId = execFileSync(ENTITY_HELPER, [
            "create",
            "--name", name,
            "--type", "person",
            "--channel", "matrix",
            "--channel-id", matrixUserId,
        ], { timeout: 5000, stdio: "pipe" }).toString().trim();

        // entity-helper.sh outputs the entity ID on the last line
        const lines = entityId.split("\n");
        const id = lines[lines.length - 1].trim();

        return { entityId: id, isNew: true, entityName: name };
    } catch (err) {
        console.error(`[MATRIX-BOT] Failed to create entity for ${matrixUserId}: ${err.message}`);
        return { entityId: "", isNew: false, entityName: name };
    }
}

/**
 * Log an interaction to Layer 0 (immutable) via entity-helper.sh.
 * Returns the interaction ID.
 */
export function logInteraction(entityId, content, direction = "inbound", channelId = "", conversationId = "") {
    if (!entityId) return "";

    const args = [
        "log-interaction", entityId,
        "--channel", "matrix",
        "--content", content,
        "--direction", direction,
    ];
    if (channelId) {
        args.push("--channel-id", channelId);
    }
    if (conversationId) {
        args.push("--conversation-id", conversationId);
    }

    try {
        const result = execFileSync(ENTITY_HELPER, args, {
            timeout: 5000,
            stdio: "pipe",
        }).toString().trim();
        // Returns interaction ID on last line
        const lines = result.split("\n");
        return lines[lines.length - 1].trim();
    } catch (err) {
        console.error(`[MATRIX-BOT] Failed to log interaction: ${err.message}`);
        return "";
    }
}

/**
 * Load entity context for building prompts.
 * Uses entity-helper.sh context with privacy filtering.
 * Returns structured context string.
 */
export function loadEntityContext(entityId, channelFilter = "matrix", limit = 20) {
    if (!entityId) return "";

    try {
        const result = execFileSync(ENTITY_HELPER, [
            "context", entityId,
            "--channel", channelFilter,
            "--limit", String(limit),
            "--privacy-filter",
        ], { timeout: 10000, stdio: "pipe" }).toString().trim();
        return result;
    } catch (err) {
        console.error(`[MATRIX-BOT] Failed to load entity context: ${err.message}`);
        return "";
    }
}

/**
 * Load entity profile summary for prompt enrichment.
 * Returns profile key-value pairs as text.
 */
export function loadEntityProfile(entityId) {
    if (!entityId) return "";

    try {
        const result = execFileSync(ENTITY_HELPER, [
            "profile", entityId,
        ], { timeout: 5000, stdio: "pipe" }).toString().trim();
        return result;
    } catch {
        return "";
    }
}

/**
 * Get or create a room session. Returns session record with entity info.
 */
export function getSession(roomId, runnerName) {
    const db = getDb();

    let session = db.prepare(
        "SELECT * FROM matrix_room_sessions WHERE room_id = ?"
    ).get(roomId);

    if (!session) {
        db.prepare(`
            INSERT INTO matrix_room_sessions (room_id, runner_name)
            VALUES (?, ?)
        `).run(roomId, runnerName);

        session = db.prepare(
            "SELECT * FROM matrix_room_sessions WHERE room_id = ?"
        ).get(roomId);
    }

    return session;
}

/**
 * Update session with entity and conversation IDs after resolution.
 */
export function updateSessionEntity(roomId, entityId, conversationId = "") {
    const db = getDb();
    db.prepare(`
        UPDATE matrix_room_sessions
        SET entity_id = ?,
            conversation_id = CASE WHEN ? != '' THEN ? ELSE conversation_id END,
            last_active = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        WHERE room_id = ?
    `).run(entityId, conversationId, conversationId, roomId);
}

/**
 * Update session_id (the upstream AI session ID) for a room.
 */
export function setSessionId(roomId, sessionId) {
    const db = getDb();
    db.prepare(`
        UPDATE matrix_room_sessions
        SET session_id = ?, last_active = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        WHERE room_id = ?
    `).run(sessionId, roomId);
}

/**
 * Record a message: logs to Layer 0 via entity-helper.sh and bumps session.
 */
export function addMessage(roomId, role, content, sender = "") {
    const db = getDb();
    const session = getSession(roomId, "");

    // Log to Layer 0 (immutable interaction log) if entity is resolved
    if (session.entity_id) {
        const direction = role === "user" ? "inbound" : "outbound";
        logInteraction(
            session.entity_id,
            content,
            direction,
            sender || roomId,
            session.conversation_id,
        );
    }

    // Bump session activity
    db.prepare(`
        UPDATE matrix_room_sessions
        SET message_count = message_count + 1,
            last_active = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        WHERE room_id = ?
    `).run(roomId);
}

/**
 * Get recent interactions for a room's entity from Layer 0.
 * Falls back to direct DB query for performance.
 */
export function getRecentMessages(roomId, limit = 50) {
    const db = getDb();
    const session = db.prepare(
        "SELECT entity_id, conversation_id FROM matrix_room_sessions WHERE room_id = ?"
    ).get(roomId);

    if (!session?.entity_id) return [];

    // Query interactions table directly for performance
    // (entity-helper.sh context command is for full context, this is for compaction)
    try {
        const rows = db.prepare(`
            SELECT direction AS role, content, channel_id AS sender, created_at
            FROM interactions
            WHERE entity_id = ?
              AND channel = 'matrix'
            ORDER BY created_at DESC
            LIMIT ?
        `).all(session.entity_id, limit);

        // Map direction to role for backward compatibility
        return rows.map(r => ({
            role: r.role === "inbound" ? "user" : "assistant",
            content: r.content,
            sender: r.sender,
            created_at: r.created_at,
        })).reverse();
    } catch {
        return [];
    }
}

/**
 * Compact a session: update conversation summary and reset session state.
 * Layer 0 interactions are NEVER deleted (immutable).
 * Only the session tracking state is reset.
 */
export function compactSession(roomId, compactedContext) {
    const db = getDb();
    const session = db.prepare(
        "SELECT entity_id, conversation_id FROM matrix_room_sessions WHERE room_id = ?"
    ).get(roomId);

    // Update conversation summary in the conversations table if we have one
    if (session?.entity_id && session?.conversation_id) {
        try {
            db.prepare(`
                UPDATE conversations
                SET summary = ?,
                    status = 'idle',
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
            `).run(compactedContext, session.conversation_id);
        } catch {
            // conversations table may not exist yet — non-fatal
        }
    }

    // Reset session state (Layer 0 interactions are preserved)
    db.prepare(`
        UPDATE matrix_room_sessions
        SET session_id = '',
            message_count = 0,
            last_active = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        WHERE room_id = ?
    `).run(roomId);
}

/**
 * Get the compacted context for a room.
 * Loads from conversation summary (Layer 1) if available.
 */
export function getCompactedContext(roomId) {
    const db = getDb();
    const session = db.prepare(
        "SELECT conversation_id FROM matrix_room_sessions WHERE room_id = ?"
    ).get(roomId);

    if (session?.conversation_id) {
        try {
            const conv = db.prepare(
                "SELECT summary FROM conversations WHERE id = ?"
            ).get(session.conversation_id);
            if (conv?.summary) return conv.summary;
        } catch {
            // conversations table may not exist — fall through
        }
    }

    return "";
}

/**
 * Find sessions that have been idle longer than the given seconds.
 */
export function getIdleSessions(idleSeconds) {
    const db = getDb();
    return db.prepare(`
        SELECT room_id, session_id, runner_name, entity_id,
               conversation_id, message_count, last_active
        FROM matrix_room_sessions
        WHERE session_id != ''
          AND message_count > 0
          AND strftime('%s', 'now') - strftime('%s', last_active) > ?
    `).all(idleSeconds);
}

/**
 * Clear a session entirely (for manual cleanup).
 * Note: Layer 0 interactions are NEVER deleted.
 */
export function clearSession(roomId) {
    const db = getDb();
    db.prepare("DELETE FROM matrix_room_sessions WHERE room_id = ?").run(roomId);
}

/**
 * List all sessions with stats.
 */
export function listSessions() {
    const db = getDb();
    return db.prepare(`
        SELECT s.room_id, s.session_id, s.runner_name, s.entity_id,
               s.message_count, s.created_at, s.last_active,
               COALESCE(e.name, '') AS entity_name,
               COALESCE(c.summary, '') AS conversation_summary
        FROM matrix_room_sessions s
        LEFT JOIN entities e ON s.entity_id = e.id
        LEFT JOIN conversations c ON s.conversation_id = c.id
        ORDER BY s.last_active DESC
    `).all();
}

/**
 * Get database stats.
 */
export function getStats() {
    const db = getDb();

    const sessionCount = db.prepare(
        "SELECT COUNT(*) AS count FROM matrix_room_sessions"
    ).get().count;

    const activeCount = db.prepare(
        "SELECT COUNT(*) AS count FROM matrix_room_sessions WHERE session_id != ''"
    ).get().count;

    let messageCount = 0;
    let entityCount = 0;
    try {
        messageCount = db.prepare(
            "SELECT COUNT(*) AS count FROM interactions WHERE channel = 'matrix'"
        ).get().count;
        entityCount = db.prepare(
            "SELECT COUNT(*) AS count FROM entity_channels WHERE channel = 'matrix'"
        ).get().count;
    } catch {
        // Entity tables may not exist yet
    }

    return { sessionCount, activeCount, messageCount, entityCount };
}

/**
 * Close the database connection (for graceful shutdown).
 */
export function close() {
    if (_db) {
        _db.close();
        _db = null;
    }
}
SESSIONSCRIPT

	log_info "Generated session store: $SESSION_STORE_SCRIPT"
}

#######################################
# Generate the Node.js bot script
#######################################
generate_bot_script() {
	cat >"$BOT_SCRIPT" <<'BOTSCRIPT'
// matrix-dispatch-bot.mjs - Entity-aware Matrix bot that dispatches to AI runners
// Generated by matrix-dispatch-helper.sh
// Do not edit directly - regenerate with: matrix-dispatch-helper.sh setup
//
// Entity integration (t1363.5):
// - Resolves Matrix user IDs to entities via entity-helper.sh
// - Logs all interactions to Layer 0 (immutable interaction log)
// - Loads entity profile + conversation context for prompts
// - Privacy-aware: filters cross-channel information

import { MatrixClient, SimpleFsStorageProvider, AutojoinRoomsMixin } from "matrix-bot-sdk";
import { readFileSync } from "fs";
import { spawn } from "child_process";
import * as store from "./session-store.mjs";

const CONFIG_PATH = process.env.MATRIX_BOT_CONFIG || `${process.env.HOME}/.config/aidevops/matrix-bot.json`;
const RUNNER_HELPER = `${process.env.HOME}/.aidevops/agents/scripts/runner-helper.sh`;
const OPENCODE_HOST = process.env.OPENCODE_HOST || "127.0.0.1";
const OPENCODE_PORT = process.env.OPENCODE_PORT || "4096";

// Entity resolution cache (Matrix user ID -> entity info)
// Avoids repeated entity-helper.sh calls for the same user within a session
const entityCache = new Map();

// Load config
function loadConfig() {
    return JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));
}

// Check if user is allowed
function isAllowed(config, userId) {
    if (!config.allowedUsers || config.allowedUsers === "") return true;
    const allowed = config.allowedUsers.split(",").map(u => u.trim());
    return allowed.includes(userId);
}

// Get runner for room
function getRunner(config, roomId) {
    const mappings = config.roomMappings || {};
    return mappings[roomId] || config.defaultRunner || null;
}

// Resolve Matrix sender to entity (cached)
function resolveEntityCached(matrixUserId, displayName = "") {
    if (entityCache.has(matrixUserId)) {
        return entityCache.get(matrixUserId);
    }
    const entity = store.resolveEntity(matrixUserId, displayName);
    if (entity.entityId) {
        entityCache.set(matrixUserId, entity);
    }
    return entity;
}

// Build the full prompt with entity-aware conversation context
function buildContextualPrompt(roomId, newPrompt, entityId = "") {
    const parts = [];

    // 1. Entity profile context (preferences, communication style, etc.)
    if (entityId) {
        const profile = store.loadEntityProfile(entityId);
        if (profile && !profile.includes("(no profile")) {
            parts.push("[Entity profile]");
            parts.push(profile);
            parts.push("[End entity profile]\n");
        }
    }

    // 2. Conversation summary from Layer 1
    const compacted = store.getCompactedContext(roomId);
    if (compacted) {
        parts.push("[Previous conversation summary]");
        parts.push(compacted);
        parts.push("[End summary]\n");
    }

    // 3. Recent interactions from Layer 0
    const recent = store.getRecentMessages(roomId, 20);
    if (recent.length > 0) {
        parts.push("[Recent messages]");
        for (const msg of recent) {
            const label = msg.role === "user" ? msg.sender || "User" : "Assistant";
            parts.push(`${label}: ${msg.content}`);
        }
        parts.push("[End recent messages]\n");
    }

    // 4. The new prompt
    parts.push(newPrompt);
    return parts.join("\n");
}

// Build a compaction prompt from the conversation history
function buildCompactionPrompt(roomId, entityId = "") {
    const compacted = store.getCompactedContext(roomId);
    const messages = store.getRecentMessages(roomId, 50);

    if (messages.length === 0 && !compacted) return null;

    const parts = [];
    parts.push("Summarise the following conversation into a concise context summary.");
    parts.push("Preserve: key decisions, facts established, user preferences, and any ongoing tasks.");
    parts.push("Omit: greetings, filler, and resolved questions.");

    // Include entity context for better summarisation
    if (entityId) {
        parts.push("Note the user's known preferences and communication style when deciding what to preserve.");
    }

    parts.push("Output ONLY the summary, no preamble.\n");

    if (compacted) {
        parts.push("[Previous summary]\n" + compacted + "\n[End previous summary]\n");
    }

    if (messages.length > 0) {
        parts.push("[Conversation to summarise]");
        for (const msg of messages) {
            const label = msg.role === "user" ? msg.sender || "User" : "Assistant";
            parts.push(`${label}: ${msg.content}`);
        }
        parts.push("[End conversation]");
    }

    return parts.join("\n");
}

// Dispatch to runner via runner-helper.sh
async function dispatchToRunner(runnerName, prompt) {
    return new Promise((resolve, reject) => {
        const args = ["run", runnerName, prompt, "--format", "json"];
        const proc = spawn(RUNNER_HELPER, args, {
            env: {
                ...process.env,
                OPENCODE_HOST,
                OPENCODE_PORT,
            },
            timeout: 600000, // 10 min
        });

        let stdout = "";
        let stderr = "";

        proc.stdout.on("data", (data) => { stdout += data.toString(); });
        proc.stderr.on("data", (data) => { stderr += data.toString(); });

        proc.on("close", (code) => {
            if (code === 0) {
                resolve(stdout.trim());
            } else {
                reject(new Error(`Runner exited with code ${code}: ${stderr}`));
            }
        });

        proc.on("error", (err) => {
            reject(err);
        });
    });
}

// Dispatch via OpenCode HTTP API directly (fallback)
async function dispatchViaAPI(prompt, runnerName) {
    const protocol = ["localhost", "127.0.0.1", "::1"].includes(OPENCODE_HOST) ? "http" : "https";
    const baseUrl = `${protocol}://${OPENCODE_HOST}:${OPENCODE_PORT}`;

    // Create session
    const sessionRes = await fetch(`${baseUrl}/session`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title: `matrix/${runnerName}` }),
    });

    if (!sessionRes.ok) throw new Error(`Failed to create session: ${sessionRes.status}`);
    const session = await sessionRes.json();

    // Send prompt
    const msgRes = await fetch(`${baseUrl}/session/${session.id}/message`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            parts: [{ type: "text", text: prompt }],
        }),
    });

    if (!msgRes.ok) throw new Error(`Failed to send message: ${msgRes.status}`);
    const response = await msgRes.json();

    // Extract text from response
    const textParts = (response.parts || [])
        .filter(p => p.type === "text")
        .map(p => p.text);

    return { sessionId: session.id, text: textParts.join("\n") || "(no response)" };
}

// Truncate long messages for Matrix
function truncateResponse(text, maxLen = 4000) {
    if (text.length <= maxLen) return text;
    return text.substring(0, maxLen - 50) + "\n\n... (truncated, full response in runner logs)";
}

// Check if a session is idle using AI judgment (conversation-helper.sh)
// Falls back to the configured timeout if conversation-helper is unavailable.
async function isSessionIdle(session, fallbackTimeout) {
    const { execSync } = require("child_process");
    const convHelper = `${process.env.HOME}/.aidevops/agents/scripts/conversation-helper.sh`;

    // Try AI-judged idle detection via conversation-helper.sh
    try {
        const fs = require("fs");
        if (fs.existsSync(convHelper)) {
            // Build a temporary conversation context for the idle check
            const messages = store.getMessages(session.room_id, 5);
            if (messages && messages.length > 0) {
                const elapsed = Math.floor((Date.now() - new Date(session.last_active).getTime()) / 1000);
                const msgText = messages.map(m => `${m.role}: ${m.content.substring(0, 150)}`).join("\n");

                // Use ai-research-helper.sh directly for a quick idle judgment
                const aiResearch = `${process.env.HOME}/.aidevops/agents/scripts/ai-research-helper.sh`;
                if (fs.existsSync(aiResearch)) {
                    const prompt = `Given these recent messages (most recent first) and that ${elapsed} seconds have passed since the last message, is this conversation idle (naturally concluded or paused) or still active (expecting a response)?\n\nRecent messages:\n${msgText}\n\nRespond with ONLY one word: 'idle' or 'active'`;
                    const result = execSync(
                        `"${aiResearch}" --model haiku --max-tokens 10 --prompt "${prompt.replace(/"/g, '\\"')}"`,
                        { timeout: 15000, encoding: "utf-8" }
                    ).trim().toLowerCase();

                    if (result === "idle" || result === "active") {
                        return result === "idle";
                    }
                }
            }
        }
    } catch (err) {
        // AI judgment unavailable — fall through to timeout-based check
        console.log(`[MATRIX-BOT] AI idle check unavailable: ${err.message}, using timeout fallback`);
    }

    // Fallback: use configured timeout (improved from flat 300s)
    const elapsed = Math.floor((Date.now() - new Date(session.last_active).getTime()) / 1000);
    return elapsed > fallbackTimeout;
}

// Compact idle sessions: summarise context, store it, destroy upstream session
// Uses AI-judged idle detection (t1363.6) instead of fixed timeout.
async function compactIdleSessions(config) {
    const fallbackTimeout = config.sessionIdleTimeout || 300;
    // Get all sessions with any activity (the AI judge decides if they're idle)
    const allSessions = store.getIdleSessions(0);

    for (const session of allSessions) {
        // Use AI judgment for idle detection, with fallback to configured timeout
        const idle = config.sessionIdleTimeout === 0
            ? true  // Shutdown mode: compact everything
            : await isSessionIdle(session, fallbackTimeout);

        if (!idle) continue;

        console.log(`[MATRIX-BOT] Compacting idle session for room ${session.room_id} (${session.message_count} messages, idle since ${session.last_active})`);

        try {
            const compactionPrompt = buildCompactionPrompt(session.room_id, session.entity_id || "");
            if (!compactionPrompt) {
                // Nothing to compact — just clear the session ID
                store.compactSession(session.room_id, store.getCompactedContext(session.room_id));
                continue;
            }

            // Dispatch compaction to the room's runner
            let summary;
            try {
                summary = await dispatchToRunner(session.runner_name, compactionPrompt);
            } catch {
                // Fallback to API
                const result = await dispatchViaAPI(compactionPrompt, session.runner_name);
                summary = result.text;

                // Clean up the temporary compaction session
                const protocol = ["localhost", "127.0.0.1", "::1"].includes(OPENCODE_HOST) ? "http" : "https";
                const baseUrl = `${protocol}://${OPENCODE_HOST}:${OPENCODE_PORT}`;
                await fetch(`${baseUrl}/session/${result.sessionId}`, { method: "DELETE" }).catch(() => {});
            }

            // Store the compacted summary (Layer 0 interactions are preserved — immutable)
            store.compactSession(session.room_id, summary);
            console.log(`[MATRIX-BOT] Compacted room ${session.room_id}: ${summary.length} chars`);

            // Destroy the upstream AI session if we have one
            if (session.session_id) {
                const protocol = ["localhost", "127.0.0.1", "::1"].includes(OPENCODE_HOST) ? "http" : "https";
                const baseUrl = `${protocol}://${OPENCODE_HOST}:${OPENCODE_PORT}`;
                await fetch(`${baseUrl}/session/${session.session_id}`, { method: "DELETE" }).catch(() => {});
            }
        } catch (err) {
            console.error(`[MATRIX-BOT] Compaction failed for room ${session.room_id}: ${err.message}`);
            // On failure, preserve existing context — don't lose data
        }
    }
}

// Main bot loop
async function main() {
    const config = loadConfig();
    const idleTimeout = config.sessionIdleTimeout || 300;

    console.log(`[MATRIX-BOT] Starting with homeserver: ${config.homeserverUrl}`);
    console.log(`[MATRIX-BOT] Bot prefix: ${config.botPrefix || "!ai"}`);
    console.log(`[MATRIX-BOT] Room mappings: ${Object.keys(config.roomMappings || {}).length}`);
    console.log(`[MATRIX-BOT] Session idle: AI-judged (fallback: ${idleTimeout}s)`);
    console.log(`[MATRIX-BOT] Entity integration: enabled (Layer 0/1 via entity-helper.sh)`);

    const matrixStorage = new SimpleFsStorageProvider(`${process.env.HOME}/.aidevops/.agent-workspace/matrix-bot/bot-storage.json`);
    const client = new MatrixClient(config.homeserverUrl, config.accessToken, matrixStorage);

    // Auto-join rooms when invited
    AutojoinRoomsMixin.setupOnClient(client);

    // Track active dispatches to prevent flooding
    const activeDispatches = new Set();

    // Get bot user ID
    const botUserId = await client.getUserId();
    console.log(`[MATRIX-BOT] Bot user: ${botUserId}`);

    // Idle session compaction timer (runs every 60s)
    const compactionInterval = setInterval(async () => {
        try {
            await compactIdleSessions(config);
        } catch (err) {
            console.error(`[MATRIX-BOT] Compaction sweep error: ${err.message}`);
        }
    }, 60000);

    client.on("room.message", async (roomId, event) => {
        // Skip own messages
        if (config.ignoreOwnMessages && event.sender === botUserId) return;

        // Skip non-text messages
        if (!event.content || event.content.msgtype !== "m.text") return;

        const body = event.content.body || "";
        const prefix = config.botPrefix || "!ai";

        // Check for bot prefix
        if (!body.startsWith(prefix)) return;

        // Extract prompt (remove prefix)
        const prompt = body.substring(prefix.length).trim();
        if (!prompt) {
            await client.sendText(roomId, `Usage: ${prefix} <your prompt here>`);
            return;
        }

        // Check user permissions
        if (!isAllowed(config, event.sender)) {
            console.log(`[MATRIX-BOT] Unauthorized user: ${event.sender}`);
            return;
        }

        // Get runner for this room
        const runnerName = getRunner(config, roomId);
        if (!runnerName) {
            await client.sendText(roomId, "This room is not mapped to a runner. Ask an admin to run:\nmatrix-dispatch-helper.sh map '" + roomId + "' <runner-name>");
            return;
        }

        // Prevent concurrent dispatches to same room
        const dispatchKey = `${roomId}:${runnerName}`;
        if (activeDispatches.has(dispatchKey)) {
            await client.sendText(roomId, `Runner '${runnerName}' is already processing a request. Please wait.`);
            return;
        }

        activeDispatches.add(dispatchKey);
        console.log(`[MATRIX-BOT] Dispatching to runner '${runnerName}' from ${event.sender} in ${roomId}`);

        // Send typing indicator
        await client.sendTyping(roomId, true, 30000).catch(() => {});

        // React with hourglass to acknowledge
        await client.sendEvent(roomId, "m.reaction", {
            "m.relates_to": {
                rel_type: "m.annotation",
                event_id: event.event_id,
                key: "\u23f3",
            },
        }).catch(() => {});

        try {
            // Ensure session exists in store
            const session = store.getSession(roomId, runnerName);

            // Entity resolution: resolve Matrix user ID to entity
            const displayName = event.content?.displayname || "";
            const entity = resolveEntityCached(event.sender, displayName);
            if (entity.entityId) {
                store.updateSessionEntity(roomId, entity.entityId);
                if (entity.isNew) {
                    console.log(`[MATRIX-BOT] Created new entity for ${event.sender}: ${entity.entityId} (${entity.entityName})`);
                }
            }

            // Record the user message (logs to Layer 0 via entity-helper.sh)
            store.addMessage(roomId, "user", prompt, event.sender);

            // Build entity-aware contextual prompt
            const contextualPrompt = buildContextualPrompt(roomId, prompt, entity.entityId);

            let response;
            try {
                // Try runner-helper.sh first
                response = await dispatchToRunner(runnerName, contextualPrompt);
            } catch (runnerErr) {
                console.log(`[MATRIX-BOT] Runner dispatch failed, trying API: ${runnerErr.message}`);
                // Fallback to direct API
                const result = await dispatchViaAPI(contextualPrompt, runnerName);
                response = result.text;

                // Track the upstream session ID
                store.setSessionId(roomId, result.sessionId);
            }

            // Record the assistant response (logs to Layer 0)
            store.addMessage(roomId, "assistant", response);

            // Truncate and send response (dynamic length based on channel)
            const maxLen = config.maxPromptLength || 3000; // Matrix default: 3000 (was 4000)
            const truncated = truncateResponse(response, maxLen);
            await client.sendText(roomId, truncated);

            // React with checkmark
            await client.sendEvent(roomId, "m.reaction", {
                "m.relates_to": {
                    rel_type: "m.annotation",
                    event_id: event.event_id,
                    key: "\u2705",
                },
            }).catch(() => {});

        } catch (err) {
            console.error(`[MATRIX-BOT] Dispatch error: ${err.message}`);
            await client.sendText(roomId, `Error dispatching to runner '${runnerName}': ${err.message}`);

            // React with X
            await client.sendEvent(roomId, "m.reaction", {
                "m.relates_to": {
                    rel_type: "m.annotation",
                    event_id: event.event_id,
                    key: "\u274c",
                },
            }).catch(() => {});
        } finally {
            activeDispatches.delete(dispatchKey);
            await client.sendTyping(roomId, false).catch(() => {});
        }
    });

    // Start syncing
    await client.start();
    console.log("[MATRIX-BOT] Bot started and syncing");

    // Graceful shutdown: compact all active sessions, then exit
    async function shutdown() {
        console.log("[MATRIX-BOT] Shutting down — compacting active sessions...");
        clearInterval(compactionInterval);

        try {
            // Compact all sessions with messages (use 0 idle timeout to catch all)
            await compactIdleSessions({ ...config, sessionIdleTimeout: 0 });
        } catch (err) {
            console.error(`[MATRIX-BOT] Shutdown compaction error: ${err.message}`);
        }

        store.close();
        client.stop();
        process.exit(0);
    }

    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);
}

main().catch((err) => {
    console.error(`[MATRIX-BOT] Fatal error: ${err.message}`);
    store.close();
    process.exit(1);
});
BOTSCRIPT

	log_info "Generated bot script: $BOT_SCRIPT"
}

#######################################
# Start the bot
#######################################
cmd_start() {
	check_deps || return 1

	if ! config_exists; then
		log_error "Bot not configured. Run: matrix-dispatch-helper.sh setup"
		return 1
	fi

	if [[ ! -f "$SESSION_STORE_SCRIPT" ]]; then
		log_info "Generating session store..."
		generate_session_store_script
	fi

	if [[ ! -f "$BOT_SCRIPT" ]]; then
		log_info "Generating bot script..."
		generate_bot_script
	fi

	if [[ ! -d "$DATA_DIR/node_modules/matrix-bot-sdk" ]] || [[ ! -d "$DATA_DIR/node_modules/better-sqlite3" ]]; then
		log_error "Dependencies not installed. Run: matrix-dispatch-helper.sh setup"
		return 1
	fi

	# Check if already running
	if [[ -f "$PID_FILE" ]]; then
		local pid
		pid=$(cat "$PID_FILE")
		if kill -0 "$pid" 2>/dev/null; then
			log_warn "Bot already running (PID: $pid)"
			return 0
		else
			rm -f "$PID_FILE"
		fi
	fi

	# Check OpenCode server
	if ! check_opencode_server; then
		log_warn "OpenCode server not responding on ${OPENCODE_HOST}:${OPENCODE_PORT}"
		echo "Start it with: opencode serve"
		echo "The bot will still start but dispatches will fail until the server is running."
	fi

	local daemon=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--daemon | -d)
			daemon=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local log_file
	log_file="$LOG_DIR/bot-$(date +%Y%m%d-%H%M%S).log"

	if [[ "$daemon" == "true" ]]; then
		log_info "Starting bot in daemon mode..."
		nohup node "$BOT_SCRIPT" >>"$log_file" 2>&1 &
		local pid=$!
		echo "$pid" >"$PID_FILE"
		log_success "Bot started (PID: $pid)"
		echo "Log: $log_file"
		echo "Stop with: matrix-dispatch-helper.sh stop"
	else
		log_info "Starting bot in foreground..."
		echo "Press Ctrl+C to stop"
		echo ""
		node "$BOT_SCRIPT" 2>&1 | tee "$log_file"
	fi

	return 0
}

#######################################
# Stop the bot
#######################################
cmd_stop() {
	if [[ ! -f "$PID_FILE" ]]; then
		log_info "Bot is not running"
		return 0
	fi

	local pid
	pid=$(cat "$PID_FILE")

	if kill -0 "$pid" 2>/dev/null; then
		log_info "Stopping bot (PID: $pid)..."
		kill "$pid"

		# Wait for graceful shutdown
		local wait_count=0
		while kill -0 "$pid" 2>/dev/null && ((wait_count < 10)); do
			sleep 1
			((wait_count++))
		done

		if kill -0 "$pid" 2>/dev/null; then
			log_warn "Force killing bot..."
			kill -9 "$pid" 2>/dev/null || true
		fi

		log_success "Bot stopped"
	else
		log_info "Bot process not found (stale PID file)"
	fi

	rm -f "$PID_FILE"
	return 0
}

#######################################
# Show bot status
#######################################
cmd_status() {
	echo -e "${BOLD}Matrix Bot Status${NC}"
	echo "──────────────────────────────────"

	# Config
	if config_exists; then
		local homeserver
		homeserver=$(config_get "homeserverUrl")
		local default_runner
		default_runner=$(config_get "defaultRunner")
		local allowed_users
		allowed_users=$(config_get "allowedUsers")
		local prefix
		prefix=$(config_get "botPrefix")

		echo "Config: $CONFIG_FILE"
		echo "Homeserver: ${homeserver:-not set}"
		echo "Bot prefix: ${prefix:-!ai}"
		echo "Default runner: ${default_runner:-none}"
		echo "Allowed users: ${allowed_users:-all}"
	else
		echo "Config: not configured"
		echo "Run: matrix-dispatch-helper.sh setup"
		return 0
	fi

	echo ""

	# Process
	if [[ -f "$PID_FILE" ]]; then
		local pid
		pid=$(cat "$PID_FILE")
		if kill -0 "$pid" 2>/dev/null; then
			echo -e "Status: ${GREEN}running${NC} (PID: $pid)"
		else
			echo -e "Status: ${RED}stopped${NC} (stale PID)"
			rm -f "$PID_FILE"
		fi
	else
		echo -e "Status: ${YELLOW}stopped${NC}"
	fi

	echo ""

	# Room mappings
	echo "Room Mappings:"
	if config_exists; then
		local mappings
		mappings=$(jq -r '.roomMappings // {} | to_entries[] | "  \(.key) -> \(.value)"' "$CONFIG_FILE" 2>/dev/null)
		if [[ -n "$mappings" ]]; then
			echo "$mappings"
		else
			echo "  (none)"
		fi
	fi

	echo ""

	# OpenCode server
	if check_opencode_server; then
		echo -e "OpenCode server: ${GREEN}running${NC} (${OPENCODE_HOST}:${OPENCODE_PORT})"
	else
		echo -e "OpenCode server: ${RED}not responding${NC} (${OPENCODE_HOST}:${OPENCODE_PORT})"
	fi

	echo ""

	# Session store — check entity-aware store first, then legacy
	if [[ -f "$MEMORY_DB" ]] && command -v sqlite3 &>/dev/null &&
		sqlite3 -cmd ".timeout 5000" "$MEMORY_DB" "SELECT 1 FROM matrix_room_sessions LIMIT 1;" &>/dev/null; then
		local total_sessions active_sessions matrix_interactions entity_count
		total_sessions=$(sqlite3 -cmd ".timeout 5000" "$MEMORY_DB" "SELECT COUNT(*) FROM matrix_room_sessions;" 2>/dev/null || echo "0")
		active_sessions=$(sqlite3 -cmd ".timeout 5000" "$MEMORY_DB" "SELECT COUNT(*) FROM matrix_room_sessions WHERE session_id != '';" 2>/dev/null || echo "0")
		matrix_interactions=$(sqlite3 -cmd ".timeout 5000" "$MEMORY_DB" "SELECT COUNT(*) FROM interactions WHERE channel = 'matrix';" 2>/dev/null || echo "0")
		entity_count=$(sqlite3 -cmd ".timeout 5000" "$MEMORY_DB" "SELECT COUNT(*) FROM entity_channels WHERE channel = 'matrix';" 2>/dev/null || echo "0")
		echo "Sessions: ${total_sessions} total, ${active_sessions} active"
		echo "Matrix interactions: ${matrix_interactions} (Layer 0, immutable)"
		echo "Matrix entities: ${entity_count}"
		echo -e "Entity integration: ${GREEN}enabled${NC}"
		echo "Session DB: $MEMORY_DB (shared memory.db)"
	elif [[ -f "$SESSION_DB" ]] && command -v sqlite3 &>/dev/null; then
		local total_sessions active_sessions
		total_sessions=$(sqlite3 -cmd ".timeout 5000" "$SESSION_DB" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "0")
		active_sessions=$(sqlite3 -cmd ".timeout 5000" "$SESSION_DB" "SELECT COUNT(*) FROM sessions WHERE session_id != '';" 2>/dev/null || echo "0")
		echo "Sessions: ${total_sessions} total, ${active_sessions} active (legacy store)"
		echo -e "Entity integration: ${YELLOW}not yet active${NC} (run setup to enable)"
		echo "Session DB: $SESSION_DB"
	else
		echo "Sessions: (no database yet)"
		echo -e "Entity integration: ${YELLOW}not yet active${NC}"
	fi

	return 0
}

#######################################
# Map a room to a runner
#######################################
cmd_map() {
	local room_id="${1:-}"
	local runner_name="${2:-}"

	if [[ -z "$room_id" || -z "$runner_name" ]]; then
		log_error "Room ID and runner name required"
		echo "Usage: matrix-dispatch-helper.sh map '<room_id>' <runner-name>"
		echo ""
		echo "Get room IDs from Element: Room Settings > Advanced > Internal room ID"
		echo "Example: matrix-dispatch-helper.sh map '!abc123:matrix.example.com' code-reviewer"
		return 1
	fi

	if ! config_exists; then
		log_error "Bot not configured. Run: matrix-dispatch-helper.sh setup"
		return 1
	fi

	# Check runner exists
	if [[ -x "$RUNNER_HELPER" ]] && ! "$RUNNER_HELPER" status "$runner_name" &>/dev/null 2>&1; then
		log_warn "Runner '$runner_name' not found. Create it with:"
		echo "  runner-helper.sh create $runner_name --description \"Description\""
	fi

	local temp_file
	temp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${temp_file}'"
	jq --arg room "$room_id" --arg runner "$runner_name" \
		'.roomMappings[$room] = $runner' "$CONFIG_FILE" >"$temp_file"
	mv "$temp_file" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE"

	log_success "Mapped room $room_id -> runner $runner_name"
	echo ""
	echo "Restart the bot to apply: matrix-dispatch-helper.sh stop && matrix-dispatch-helper.sh start --daemon"

	return 0
}

#######################################
# Remove a room mapping
#######################################
cmd_unmap() {
	local room_id="${1:-}"

	if [[ -z "$room_id" ]]; then
		log_error "Room ID required"
		echo "Usage: matrix-dispatch-helper.sh unmap '<room_id>'"
		return 1
	fi

	if ! config_exists; then
		log_error "Bot not configured"
		return 1
	fi

	local temp_file
	temp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${temp_file}'"
	jq --arg room "$room_id" 'del(.roomMappings[$room])' "$CONFIG_FILE" >"$temp_file"
	mv "$temp_file" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE"

	log_success "Removed mapping for room $room_id"
	return 0
}

#######################################
# List room-to-runner mappings
#######################################
cmd_mappings() {
	if ! config_exists; then
		log_error "Bot not configured"
		return 1
	fi

	echo -e "${BOLD}Room-to-Runner Mappings${NC}"
	echo "──────────────────────────────────"

	local mappings
	mappings=$(jq -r '.roomMappings // {} | to_entries[] | "\(.key)\t\(.value)"' "$CONFIG_FILE" 2>/dev/null)

	if [[ -z "$mappings" ]]; then
		echo "(no mappings)"
		echo ""
		echo "Add one with: matrix-dispatch-helper.sh map '<room_id>' <runner-name>"
		return 0
	fi

	printf "%-45s %s\n" "Room ID" "Runner"
	printf "%-45s %s\n" "─────────────────────────────────────────────" "──────────────────"

	while IFS=$'\t' read -r room runner; do
		printf "%-45s %s\n" "$room" "$runner"
	done <<<"$mappings"

	local default_runner
	default_runner=$(config_get "defaultRunner")
	if [[ -n "$default_runner" ]]; then
		echo ""
		echo "Default runner (unmapped rooms): $default_runner"
	fi

	return 0
}

#######################################
# Test dispatch without Matrix
#######################################
cmd_test() {
	local room_or_runner="${1:-}"
	local message="${2:-}"

	if [[ -z "$room_or_runner" || -z "$message" ]]; then
		log_error "Room/runner and message required"
		echo "Usage: matrix-dispatch-helper.sh test <room-id-or-runner> \"message\""
		return 1
	fi

	# Determine runner name
	local runner_name="$room_or_runner"
	if config_exists; then
		local mapped_runner
		mapped_runner=$(jq -r --arg room "$room_or_runner" '.roomMappings[$room] // empty' "$CONFIG_FILE" 2>/dev/null)
		if [[ -n "$mapped_runner" ]]; then
			runner_name="$mapped_runner"
			log_info "Room $room_or_runner maps to runner: $runner_name"
		fi
	fi

	log_info "Testing dispatch to runner: $runner_name"
	log_info "Message: $message"
	echo ""

	if [[ -x "$RUNNER_HELPER" ]]; then
		"$RUNNER_HELPER" run "$runner_name" "$message"
	else
		log_error "runner-helper.sh not found at $RUNNER_HELPER"
		return 1
	fi

	return 0
}

#######################################
# View logs
#######################################
cmd_logs() {
	local tail_lines=50
	local follow=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tail)
			[[ $# -lt 2 ]] && {
				log_error "--tail requires a value"
				return 1
			}
			tail_lines="$2"
			shift 2
			;;
		--follow | -f)
			follow=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ ! -d "$LOG_DIR" ]]; then
		log_info "No logs found"
		return 0
	fi

	local latest
	latest=$(find "$LOG_DIR" -name "*.log" -type f 2>/dev/null | sort -r | head -1)

	if [[ -z "$latest" ]]; then
		log_info "No log files found"
		return 0
	fi

	if [[ "$follow" == "true" ]]; then
		log_info "Following: $(basename "$latest")"
		tail -f "$latest"
	else
		echo -e "${BOLD}Latest log: $(basename "$latest")${NC}"
		tail -n "$tail_lines" "$latest"
	fi

	return 0
}

#######################################
# Manage conversation sessions
#######################################
cmd_sessions() {
	local subcmd="${1:-list}"
	shift || true

	if ! command -v sqlite3 &>/dev/null; then
		log_error "sqlite3 required for session management"
		return 1
	fi

	ensure_dirs

	# Use shared memory.db for entity-aware sessions
	local db_path="$MEMORY_DB"
	local table_name="matrix_room_sessions"

	# Fall back to legacy sessions.db if memory.db doesn't have the table
	if [[ ! -f "$db_path" ]] || ! sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT 1 FROM $table_name LIMIT 1;" &>/dev/null; then
		if [[ -f "$SESSION_DB" ]]; then
			db_path="$SESSION_DB"
			table_name="sessions"
			log_info "Using legacy session store: $SESSION_DB"
		else
			if [[ "$subcmd" == "list" ]]; then
				echo -e "${BOLD}Conversation Sessions${NC}"
				echo "──────────────────────────────────"
				echo "(no sessions — database not yet created)"
				echo "Sessions are created automatically when the bot processes messages."
				return 0
			fi
			log_info "No session database"
			return 0
		fi
	fi

	case "$subcmd" in
	list)
		echo -e "${BOLD}Conversation Sessions${NC}"
		echo "──────────────────────────────────"

		local sessions
		if [[ "$table_name" == "matrix_room_sessions" ]]; then
			sessions=$(sqlite3 -cmd ".timeout 5000" -separator '|' "$db_path" \
				"SELECT s.room_id, s.runner_name, s.message_count, COALESCE(e.name, ''), s.entity_id, s.last_active
				 FROM matrix_room_sessions s
				 LEFT JOIN entities e ON s.entity_id = e.id
				 ORDER BY s.last_active DESC;" 2>/dev/null)

			if [[ -z "$sessions" ]]; then
				echo "(no sessions)"
				return 0
			fi

			printf "%-35s %-15s %5s %-20s %s\n" "Room ID" "Runner" "Msgs" "Entity" "Last Active"
			printf "%-35s %-15s %5s %-20s %s\n" "───────────────────────────────────" "───────────────" "─────" "────────────────────" "───────────────────"

			while IFS='|' read -r room runner msgs entity_name entity_id active; do
				local entity_display="${entity_name:-${entity_id:-(none)}}"
				printf "%-35s %-15s %5s %-20s %s\n" "$room" "$runner" "$msgs" "$entity_display" "$active"
			done <<<"$sessions"
		else
			# Legacy format
			sessions=$(sqlite3 -cmd ".timeout 5000" -separator '|' "$db_path" \
				"SELECT room_id, runner_name, message_count, length(compacted_context), last_active FROM sessions ORDER BY last_active DESC;" 2>/dev/null)

			if [[ -z "$sessions" ]]; then
				echo "(no sessions)"
				return 0
			fi

			printf "%-40s %-18s %6s %8s %s\n" "Room ID" "Runner" "Msgs" "Context" "Last Active"
			printf "%-40s %-18s %6s %8s %s\n" "────────────────────────────────────────" "──────────────────" "──────" "────────" "───────────────────"

			while IFS='|' read -r room runner msgs ctx_bytes active; do
				local ctx_display
				if [[ "$ctx_bytes" -gt 1024 ]]; then
					ctx_display="$((ctx_bytes / 1024))KB"
				else
					ctx_display="${ctx_bytes}B"
				fi
				printf "%-40s %-18s %6s %8s %s\n" "$room" "$runner" "$msgs" "$ctx_display" "$active"
			done <<<"$sessions"
		fi
		;;

	clear)
		local room_id="${1:-}"
		if [[ -z "$room_id" ]]; then
			log_error "Room ID required"
			echo "Usage: matrix-dispatch-helper.sh sessions clear '<room_id>'"
			return 1
		fi

		# Clear from entity-aware table (Layer 0 interactions are preserved — immutable)
		sqlite3 -cmd ".timeout 5000" "$db_path" \
			"DELETE FROM $table_name WHERE room_id = '$(echo "$room_id" | sed "s/'/''/g")';" 2>/dev/null
		log_success "Cleared session for room $room_id"
		log_info "Note: Layer 0 interactions are preserved (immutable). Only session state was cleared."
		;;

	clear-all)
		sqlite3 -cmd ".timeout 5000" "$db_path" \
			"DELETE FROM $table_name;" 2>/dev/null
		log_success "Cleared all sessions"
		log_info "Note: Layer 0 interactions are preserved (immutable). Only session state was cleared."
		;;

	stats)
		echo -e "${BOLD}Session Statistics${NC}"
		echo "──────────────────────────────────"

		if [[ "$table_name" == "matrix_room_sessions" ]]; then
			local total_sessions active_sessions matrix_interactions entity_count db_size
			total_sessions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM matrix_room_sessions;" 2>/dev/null || echo "0")
			active_sessions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM matrix_room_sessions WHERE session_id != '';" 2>/dev/null || echo "0")
			matrix_interactions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM interactions WHERE channel = 'matrix';" 2>/dev/null || echo "0")
			entity_count=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM entity_channels WHERE channel = 'matrix';" 2>/dev/null || echo "0")
			db_size=$(stat -f%z "$db_path" 2>/dev/null || stat -c%s "$db_path" 2>/dev/null || echo "0")

			echo "Total sessions:       ${total_sessions:-0}"
			echo "Active sessions:      ${active_sessions:-0}"
			echo "Matrix interactions:  ${matrix_interactions:-0} (Layer 0, immutable)"
			echo "Matrix entities:      ${entity_count:-0}"
			echo "Database:             $db_path ($((${db_size:-0} / 1024))KB)"
		else
			local total_sessions active_sessions total_messages context_bytes db_size
			total_sessions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "0")
			active_sessions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM sessions WHERE session_id != '';" 2>/dev/null || echo "0")
			total_messages=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM message_log;" 2>/dev/null || echo "0")
			context_bytes=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COALESCE(SUM(length(compacted_context)), 0) FROM sessions;" 2>/dev/null || echo "0")
			db_size=$(stat -f%z "$db_path" 2>/dev/null || stat -c%s "$db_path" 2>/dev/null || echo "0")

			echo "Total sessions:    ${total_sessions:-0} (legacy store)"
			echo "Active sessions:   ${active_sessions:-0}"
			echo "Messages in log:   ${total_messages:-0}"
			echo "Compacted context: $((${context_bytes:-0} / 1024))KB"
			echo "Database size:     $((${db_size:-0} / 1024))KB"
		fi
		;;

	*)
		log_error "Unknown sessions subcommand: $subcmd"
		echo "Usage: matrix-dispatch-helper.sh sessions [list|clear <room>|clear-all|stats]"
		return 1
		;;
	esac

	return 0
}

#######################################
# Generate a random password (alphanumeric, 32 chars)
#######################################
generate_password() {
	local length="${1:-32}"
	LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
	return 0
}

#######################################
# Extract the Matrix server name from a homeserver URL
# e.g., https://matrix.example.com -> example.com
#######################################
extract_server_name() {
	local homeserver_url="$1"
	local domain
	domain=$(echo "$homeserver_url" | sed -E 's|https?://||' | sed 's|/.*||')

	# If domain starts with "matrix.", strip it for the server name
	if [[ "$domain" == matrix.* ]]; then
		echo "${domain#matrix.}"
	else
		echo "$domain"
	fi
	return 0
}

#######################################
# Synapse Admin API: Register bot user
#######################################
# Usage: synapse_register_bot_user <homeserver_url> <admin_token> <user_id> <password> [display_name]
# Example: synapse_register_bot_user "https://matrix.example.com" "syt_..." "@bot:example.com" "secret123" "My Bot"
synapse_register_bot_user() {
	local homeserver_url="$1"
	local admin_token="$2"
	local user_id="$3"
	local password="$4"
	local display_name="${5:-}"

	if [[ -z "$homeserver_url" || -z "$admin_token" || -z "$user_id" || -z "$password" ]]; then
		log_error "Usage: synapse_register_bot_user <homeserver_url> <admin_token> <user_id> <password> [display_name]"
		return 1
	fi

	# URL-encode the user ID for the path
	local encoded_user_id
	encoded_user_id=$(printf '%s' "$user_id" | jq -sRr @uri)

	local endpoint="${homeserver_url}/_synapse/admin/v2/users/${encoded_user_id}"

	local json_body
	json_body=$(jq -n \
		--arg password "$password" \
		--arg displayname "$display_name" \
		--argjson admin false \
		'{
			password: $password,
			admin: $admin,
			displayname: (if $displayname != "" then $displayname else null end)
		}')

	log_info "Registering bot user: $user_id"

	local response
	response=$(curl -sf -X PUT "$endpoint" \
		-H "Authorization: Bearer $admin_token" \
		-H "Content-Type: application/json" \
		-d "$json_body" 2>&1)

	local exit_code=$?

	if [[ $exit_code -eq 0 ]]; then
		log_success "Bot user registered successfully"
		echo "$response" | jq '.'
		return 0
	else
		log_error "Failed to register bot user"
		echo "$response"
		return 1
	fi
}

#######################################
# Matrix Client API: Login and get access token
#######################################
# Usage: matrix_login <homeserver_url> <user_id> <password>
# Example: matrix_login "https://matrix.example.com" "@bot:example.com" "secret123"
matrix_login() {
	local homeserver_url="$1"
	local user_id="$2"
	local password="$3"

	if [[ -z "$homeserver_url" || -z "$user_id" || -z "$password" ]]; then
		log_error "Usage: matrix_login <homeserver_url> <user_id> <password>"
		return 1
	fi

	local endpoint="${homeserver_url}/_matrix/client/v3/login"

	local json_body
	json_body=$(jq -n \
		--arg type "m.login.password" \
		--arg user "$user_id" \
		--arg password "$password" \
		'{
			type: $type,
			identifier: {
				type: "m.id.user",
				user: $user
			},
			password: $password
		}')

	log_info "Logging in as: $user_id"

	local response
	response=$(curl -sf -X POST "$endpoint" \
		-H "Content-Type: application/json" \
		-d "$json_body" 2>&1)

	local exit_code=$?

	if [[ $exit_code -eq 0 ]]; then
		log_success "Login successful"
		echo "$response" | jq '.'
		return 0
	else
		log_error "Login failed"
		echo "$response"
		return 1
	fi
}

#######################################
# Matrix Client API: Create room
#######################################
# Usage: matrix_create_room <homeserver_url> <access_token> <room_name> [room_alias] [is_public]
# Example: matrix_create_room "https://matrix.example.com" "syt_..." "My Room" "myroom" "false"
matrix_create_room() {
	local homeserver_url="$1"
	local access_token="$2"
	local room_name="$3"
	local room_alias="${4:-}"
	local is_public="${5:-false}"

	if [[ -z "$homeserver_url" || -z "$access_token" || -z "$room_name" ]]; then
		log_error "Usage: matrix_create_room <homeserver_url> <access_token> <room_name> [room_alias] [is_public]"
		return 1
	fi

	local endpoint="${homeserver_url}/_matrix/client/v3/createRoom"

	local preset
	if [[ "$is_public" == "true" ]]; then
		preset="public_chat"
	else
		preset="private_chat"
	fi

	local json_body
	json_body=$(jq -n \
		--arg name "$room_name" \
		--arg alias "$room_alias" \
		--arg preset "$preset" \
		'{
			name: $name,
			room_alias_name: (if $alias != "" then $alias else null end),
			preset: $preset,
			visibility: (if $preset == "public_chat" then "public" else "private" end)
		}')

	log_info "Creating room: $room_name"

	local response
	response=$(curl -sf -X POST "$endpoint" \
		-H "Authorization: Bearer $access_token" \
		-H "Content-Type: application/json" \
		-d "$json_body" 2>&1)

	local exit_code=$?

	if [[ $exit_code -eq 0 ]]; then
		log_success "Room created successfully"
		echo "$response" | jq '.'
		return 0
	else
		log_error "Failed to create room"
		echo "$response"
		return 1
	fi
}

#######################################
# Matrix Client API: Invite user to room
#######################################
# Usage: matrix_invite_user <homeserver_url> <access_token> <room_id> <user_id>
# Example: matrix_invite_user "https://matrix.example.com" "syt_..." "!abc:example.com" "@user:example.com"
matrix_invite_user() {
	local homeserver_url="$1"
	local access_token="$2"
	local room_id="$3"
	local user_id="$4"

	if [[ -z "$homeserver_url" || -z "$access_token" || -z "$room_id" || -z "$user_id" ]]; then
		log_error "Usage: matrix_invite_user <homeserver_url> <access_token> <room_id> <user_id>"
		return 1
	fi

	# URL-encode the room ID for the path
	local encoded_room_id
	encoded_room_id=$(printf '%s' "$room_id" | jq -sRr @uri)

	local endpoint="${homeserver_url}/_matrix/client/v3/rooms/${encoded_room_id}/invite"

	local json_body
	json_body=$(jq -n \
		--arg user_id "$user_id" \
		'{
			user_id: $user_id
		}')

	log_info "Inviting $user_id to room $room_id"

	local response
	response=$(curl -sf -X POST "$endpoint" \
		-H "Authorization: Bearer $access_token" \
		-H "Content-Type: application/json" \
		-d "$json_body" 2>&1)

	local exit_code=$?

	if [[ $exit_code -eq 0 ]]; then
		log_success "User invited successfully"
		echo "$response" | jq '.'
		return 0
	else
		log_error "Failed to invite user"
		echo "$response"
		return 1
	fi
}

#######################################
# Non-interactive setup (writes config without prompts)
#######################################
cmd_setup_noninteractive() {
	local homeserver_url="$1"
	local access_token="$2"
	local allowed_users="${3:-}"
	local default_runner="${4:-}"
	local idle_timeout="${5:-300}"

	if [[ -z "$homeserver_url" || -z "$access_token" ]]; then
		log_error "Usage: cmd_setup_noninteractive <homeserver_url> <access_token> [allowed_users] [default_runner] [idle_timeout]"
		return 1
	fi

	check_deps || return 1
	ensure_dirs

	# Write config
	local temp_file
	temp_file=$(mktemp)
	trap 'rm -f "$temp_file"' RETURN

	local existing_mappings='{}'
	if [[ -f "$CONFIG_FILE" ]]; then
		existing_mappings=$(jq -r '.roomMappings // {}' "$CONFIG_FILE" 2>/dev/null || echo '{}')
	fi

	jq -n \
		--arg homeserverUrl "$homeserver_url" \
		--arg accessToken "$access_token" \
		--arg allowedUsers "$allowed_users" \
		--arg defaultRunner "$default_runner" \
		--argjson sessionIdleTimeout "$idle_timeout" \
		--argjson roomMappings "$existing_mappings" \
		'{
			homeserverUrl: $homeserverUrl,
			accessToken: $accessToken,
			allowedUsers: $allowedUsers,
			defaultRunner: $defaultRunner,
			roomMappings: $roomMappings,
			botPrefix: "!ai",
			ignoreOwnMessages: true,
			maxPromptLength: 3000,
			responseTimeout: 600,
			sessionIdleTimeout: $sessionIdleTimeout
		}' >"$temp_file"
	mv "$temp_file" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE"

	# Install dependencies if needed
	local needs_install=false
	if [[ ! -d "$DATA_DIR/node_modules/matrix-bot-sdk" ]]; then
		needs_install=true
	fi
	if [[ ! -d "$DATA_DIR/node_modules/better-sqlite3" ]]; then
		needs_install=true
	fi

	if [[ "$needs_install" == "true" ]]; then
		log_info "Installing dependencies (matrix-bot-sdk, better-sqlite3)..."
		npm install --prefix "$DATA_DIR" matrix-bot-sdk better-sqlite3 2>/dev/null || {
			log_error "Failed to install dependencies"
			return 1
		}
		log_success "Dependencies installed"
	fi

	# Generate scripts
	generate_session_store_script
	generate_bot_script

	log_success "Non-interactive setup complete"
	return 0
}

#######################################
# Auto-setup: Full end-to-end provisioning
#
# Orchestrates: Cloudron Synapse install -> bot user creation ->
# access token -> bot config -> room creation -> room mapping
#
# Usage:
#   matrix-dispatch-helper.sh auto-setup <cloudron-server> [options]
#
# Options:
#   --subdomain <name>     Synapse subdomain (default: matrix)
#   --bot-user <name>      Bot username (default: aibot)
#   --bot-display <name>   Bot display name (default: AI DevOps Bot)
#   --runners <list>       Comma-separated runner names for room creation
#   --allowed-users <list> Comma-separated Matrix user IDs to allow
#   --dry-run              Show what would be done without executing
#   --skip-install         Skip Synapse installation (already installed)
#   --admin-token <token>  Use existing Synapse admin token instead of auto-detecting
#######################################
cmd_auto_setup() {
	local cloudron_server=""
	local subdomain="matrix"
	local bot_user="aibot"
	local bot_display="AI DevOps Bot"
	local runners=""
	local allowed_users=""
	local dry_run=false
	local skip_install=false
	local admin_token=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--subdomain)
			subdomain="$2"
			shift 2
			;;
		--bot-user)
			bot_user="$2"
			shift 2
			;;
		--bot-display)
			bot_display="$2"
			shift 2
			;;
		--runners)
			runners="$2"
			shift 2
			;;
		--allowed-users)
			allowed_users="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--skip-install)
			skip_install=true
			shift
			;;
		--admin-token)
			admin_token="$2"
			shift 2
			;;
		-*)
			log_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$cloudron_server" ]]; then
				cloudron_server="$1"
			else
				log_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	if [[ -z "$cloudron_server" ]]; then
		log_error "Cloudron server name is required"
		echo ""
		echo "Usage: matrix-dispatch-helper.sh auto-setup <cloudron-server> [options]"
		echo ""
		echo "Options:"
		echo "  --subdomain <name>     Synapse subdomain (default: matrix)"
		echo "  --bot-user <name>      Bot username (default: aibot)"
		echo "  --bot-display <name>   Bot display name (default: AI DevOps Bot)"
		echo "  --runners <list>       Comma-separated runner names for room creation"
		echo "  --allowed-users <list> Comma-separated allowed Matrix user IDs"
		echo "  --dry-run              Show plan without executing"
		echo "  --skip-install         Skip Synapse installation (already installed)"
		echo "  --admin-token <token>  Use existing Synapse admin token"
		echo ""
		echo "Example:"
		echo "  matrix-dispatch-helper.sh auto-setup cloudron01 --runners code-reviewer,seo-analyst,ops-monitor"
		return 1
	fi

	check_deps || return 1
	ensure_dirs

	# Resolve Cloudron server config
	local cloudron_helper="${SCRIPT_DIR}/cloudron-helper.sh"
	if [[ ! -x "$cloudron_helper" ]]; then
		log_error "cloudron-helper.sh not found at $cloudron_helper"
		return 1
	fi

	# Try multiple config locations: repo root configs/, relative to script, CWD-relative
	local cloudron_config=""
	local -a config_paths=(
		"${SCRIPT_DIR}/../../configs/cloudron-config.json"
		"${SCRIPT_DIR}/../configs/cloudron-config.json"
		"configs/cloudron-config.json"
		"../configs/cloudron-config.json"
	)
	for candidate in "${config_paths[@]}"; do
		if [[ -f "$candidate" ]]; then
			cloudron_config="$candidate"
			break
		fi
	done

	if [[ -z "$cloudron_config" ]]; then
		log_error "Cloudron config not found"
		log_info "Copy and customize: cp configs/cloudron-config.json.txt configs/cloudron-config.json"
		return 1
	fi

	local server_domain
	server_domain=$(jq -r ".servers.\"$cloudron_server\".domain" "$cloudron_config" 2>/dev/null)
	local server_token
	server_token=$(jq -r ".servers.\"$cloudron_server\".api_token" "$cloudron_config" 2>/dev/null)

	if [[ "$server_domain" == "null" || -z "$server_domain" ]]; then
		log_error "Server '$cloudron_server' not found in Cloudron config"
		log_info "Available servers:"
		jq -r '.servers | keys[]' "$cloudron_config" 2>/dev/null | while read -r s; do
			echo "  - $s"
		done
		return 1
	fi

	if [[ "$server_token" == "null" || -z "$server_token" || "$server_token" == *"YOUR_"* ]]; then
		log_error "API token not configured for server '$cloudron_server'"
		log_info "Set it in: configs/cloudron-config.json"
		return 1
	fi

	local homeserver_url="https://${subdomain}.${server_domain}"
	local server_name
	server_name=$(extract_server_name "$homeserver_url")
	local bot_user_id="@${bot_user}:${server_name}"
	local bot_password
	bot_password=$(generate_password 32)

	# Synapse app store ID on Cloudron
	local synapse_app_id="org.matrix.synapse.cloudronapp"

	echo -e "${BOLD}Matrix Bot Auto-Setup${NC}"
	echo "──────────────────────────────────"
	echo ""
	echo "Cloudron server:  $cloudron_server ($server_domain)"
	echo "Synapse URL:      $homeserver_url"
	echo "Bot user:         $bot_user_id"
	echo "Bot display name: $bot_display"
	echo "Runners:          ${runners:-none (add later with 'map' command)}"
	echo "Allowed users:    ${allowed_users:-all}"
	echo ""

	if [[ "$dry_run" == "true" ]]; then
		echo -e "${YELLOW}[DRY RUN]${NC} The following steps would be executed:"
		echo ""
		if [[ "$skip_install" != "true" ]]; then
			echo "  1. Install Synapse on Cloudron at $subdomain.$server_domain"
			echo "  2. Wait for Synapse to be ready"
		else
			echo "  1-2. (skipped — Synapse already installed)"
		fi
		echo "  3. Register bot user: $bot_user_id"
		echo "  4. Login as bot to get access token"
		echo "  5. Store credentials via aidevops secret"
		echo "  6. Configure matrix-dispatch-helper.sh"
		if [[ -n "$runners" ]]; then
			echo "  7. Create rooms and map to runners:"
			IFS=',' read -ra runner_list <<<"$runners"
			for runner in "${runner_list[@]}"; do
				runner=$(echo "$runner" | tr -d ' ')
				echo "     - Room: #${runner}:${server_name} -> runner: $runner"
			done
		else
			echo "  7. (no runners specified — skip room creation)"
		fi
		echo "  8. Install npm dependencies and generate bot scripts"
		echo ""
		echo "Run without --dry-run to execute."
		return 0
	fi

	# ── Step 1: Install Synapse on Cloudron ──
	local app_id=""
	if [[ "$skip_install" != "true" ]]; then
		log_info "Step 1/8: Installing Synapse on Cloudron..."

		app_id=$("$cloudron_helper" install-app "$cloudron_server" "$synapse_app_id" "$subdomain" 2>&1)
		local install_exit=$?

		if [[ $install_exit -ne 0 ]]; then
			# Check if already installed
			local existing_app
			existing_app=$("$cloudron_helper" app-info "$cloudron_server" "$subdomain" 2>/dev/null)
			if [[ -n "$existing_app" ]]; then
				log_warn "Synapse appears to already be installed at $subdomain.$server_domain"
				app_id=$(echo "$existing_app" | jq -r '.id')
			else
				log_error "Failed to install Synapse: $app_id"
				return 1
			fi
		fi

		# Extract just the app ID (last line of output from install_app)
		app_id=$(echo "$app_id" | tail -1 | tr -d '[:space:]')
		log_success "Synapse installation initiated (app ID: $app_id)"

		# ── Step 2: Wait for Synapse to be ready ──
		log_info "Step 2/8: Waiting for Synapse to be ready..."
		if ! "$cloudron_helper" wait-ready "$cloudron_server" "$app_id" 600; then
			log_error "Synapse failed to become ready within 10 minutes"
			return 1
		fi
		log_success "Synapse is ready"
	else
		log_info "Step 1-2/8: Skipping Synapse installation (--skip-install)"

		# Verify Synapse is accessible
		local health_check
		health_check=$(curl -sf "${homeserver_url}/_matrix/client/versions" 2>/dev/null)
		if [[ -z "$health_check" ]]; then
			log_error "Synapse not responding at $homeserver_url"
			log_info "Verify Synapse is installed and running on Cloudron"
			return 1
		fi
		log_success "Synapse is accessible at $homeserver_url"
	fi

	# ── Step 3: Get admin token and register bot user ──
	log_info "Step 3/8: Registering bot user..."

	if [[ -z "$admin_token" ]]; then
		# Try to get admin token from aidevops secrets
		local secret_name="SYNAPSE_ADMIN_TOKEN_${cloudron_server}"
		admin_token=$(gopass show "aidevops/${secret_name}" 2>/dev/null || true)

		if [[ -z "$admin_token" ]]; then
			log_error "Synapse admin token not found"
			echo ""
			echo "To get the admin token:"
			echo "  1. Create an admin user on Synapse (via Cloudron dashboard or register_new_matrix_user)"
			echo "  2. Login via the Matrix API to get an access token"
			echo "  3. Store it: aidevops secret set ${secret_name}"
			echo ""
			echo "Or pass it directly: --admin-token <token>"
			return 1
		fi
	fi

	local register_result
	register_result=$(synapse_register_bot_user "$homeserver_url" "$admin_token" "$bot_user_id" "$bot_password" "$bot_display" 2>&1)
	local register_exit=$?

	if [[ $register_exit -ne 0 ]]; then
		log_error "Failed to register bot user: $register_result"
		return 1
	fi
	log_success "Bot user registered: $bot_user_id"

	# ── Step 4: Login as bot to get access token ──
	log_info "Step 4/8: Logging in as bot user..."

	local login_result
	login_result=$(matrix_login "$homeserver_url" "$bot_user_id" "$bot_password" 2>&1)
	local login_exit=$?

	if [[ $login_exit -ne 0 ]]; then
		log_error "Failed to login as bot: $login_result"
		return 1
	fi

	local bot_access_token
	bot_access_token=$(echo "$login_result" | jq -r '.access_token // empty' 2>/dev/null)

	if [[ -z "$bot_access_token" ]]; then
		log_error "Failed to extract access token from login response"
		return 1
	fi
	log_success "Bot access token obtained"

	# ── Step 5: Store credentials securely ──
	log_info "Step 5/8: Storing credentials..."

	# Store bot password and token via gopass if available
	local secret_prefix="MATRIX_BOT_${cloudron_server}"
	if command -v gopass &>/dev/null; then
		echo "$bot_password" | gopass insert -f "aidevops/${secret_prefix}_PASSWORD" 2>/dev/null || {
			log_warn "Failed to store bot password in gopass"
		}
		echo "$bot_access_token" | gopass insert -f "aidevops/${secret_prefix}_TOKEN" 2>/dev/null || {
			log_warn "Failed to store bot token in gopass"
		}
		log_success "Credentials stored in gopass (aidevops/${secret_prefix}_*)"
	else
		log_warn "gopass not available — credentials stored only in config file"
		log_info "Install gopass for encrypted credential storage: aidevops secret set"
	fi

	# ── Step 6: Configure the bot non-interactively ──
	log_info "Step 6/8: Configuring bot..."

	cmd_setup_noninteractive "$homeserver_url" "$bot_access_token" "$allowed_users" "" "$DEFAULT_TIMEOUT"
	log_success "Bot configured"

	# ── Step 7: Create rooms and map to runners ──
	if [[ -n "$runners" ]]; then
		log_info "Step 7/8: Creating rooms and mapping to runners..."

		IFS=',' read -ra runner_list <<<"$runners"
		for runner in "${runner_list[@]}"; do
			runner=$(echo "$runner" | tr -d ' ')
			local room_name="AI: ${runner}"
			local room_alias="${runner}"

			log_info "Creating room for runner: $runner"

			local room_result
			room_result=$(matrix_create_room "$homeserver_url" "$bot_access_token" "$room_name" "$room_alias" "false" 2>&1)
			local room_exit=$?

			if [[ $room_exit -ne 0 ]]; then
				log_warn "Failed to create room for $runner: $room_result"
				continue
			fi

			local room_id
			room_id=$(echo "$room_result" | jq -r '.room_id // empty' 2>/dev/null)

			if [[ -z "$room_id" ]]; then
				log_warn "Failed to extract room ID for $runner"
				continue
			fi

			log_success "Room created: $room_id ($room_name)"

			# Map room to runner
			cmd_map "$room_id" "$runner"

			# Invite the admin user(s) to the room
			if [[ -n "$allowed_users" ]]; then
				IFS=',' read -ra user_list <<<"$allowed_users"
				for user in "${user_list[@]}"; do
					user=$(echo "$user" | tr -d ' ')
					log_info "Inviting $user to room $room_id"
					matrix_invite_user "$homeserver_url" "$bot_access_token" "$room_id" "$user" 2>/dev/null || {
						log_warn "Failed to invite $user to $room_id"
					}
				done
			fi
		done

		log_success "Room creation and mapping complete"
	else
		log_info "Step 7/8: No runners specified — skipping room creation"
		log_info "Map rooms later with: matrix-dispatch-helper.sh map '<room_id>' <runner>"
	fi

	# ── Step 8: Summary ──
	log_info "Step 8/8: Finalizing..."

	echo ""
	echo -e "${BOLD}Auto-Setup Complete!${NC}"
	echo "──────────────────────────────────"
	echo ""
	echo "Homeserver:    $homeserver_url"
	echo "Bot user:      $bot_user_id"
	echo "Config:        $CONFIG_FILE"
	echo ""

	if [[ -n "$runners" ]]; then
		echo "Room mappings:"
		jq -r '.roomMappings // {} | to_entries[] | "  \(.key) -> \(.value)"' "$CONFIG_FILE" 2>/dev/null
		echo ""
	fi

	echo "Next steps:"
	echo "  1. Start the bot:"
	echo "     matrix-dispatch-helper.sh start --daemon"
	echo ""
	if [[ -z "$runners" ]]; then
		echo "  2. Map rooms to runners:"
		echo "     matrix-dispatch-helper.sh map '!roomid:server' my-runner"
		echo ""
	fi
	echo "  3. In a mapped Matrix room, type:"
	echo "     !ai Review the auth module for security issues"
	echo ""

	if command -v gopass &>/dev/null; then
		echo "Credentials stored in gopass:"
		echo "  aidevops/${secret_prefix}_PASSWORD"
		echo "  aidevops/${secret_prefix}_TOKEN"
	fi

	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
matrix-dispatch-helper.sh - Matrix bot for AI runner dispatch

USAGE:
    matrix-dispatch-helper.sh <command> [options]

COMMANDS:
    setup [--dry-run]           Interactive setup wizard (--dry-run to preview without saving)
    auto-setup <server> [opts]  Full automated provisioning (Cloudron + Synapse)
    start [--daemon]            Start the bot (foreground or daemon)
    stop                        Stop the bot (compacts all active sessions first)
    status                      Show bot status and configuration
    map <room> <runner>         Map a Matrix room to a runner
    unmap <room>                Remove a room mapping
    mappings                    List all room-to-runner mappings
    sessions [list|clear|stats] Manage per-channel conversation sessions
    test <room|runner> "msg"    Test dispatch without Matrix
    logs [--tail N] [--follow]  View bot logs
    help                        Show this help

SYNAPSE ADMIN API FUNCTIONS (for scripting):
    Source this script to use these functions in your own scripts:
        source matrix-dispatch-helper.sh

    synapse_register_bot_user <homeserver_url> <admin_token> <user_id> <password> [display_name]
        Register a new bot user via Synapse Admin API
        Example: synapse_register_bot_user "https://matrix.example.com" "syt_..." "@bot:example.com" "secret123" "My Bot"

    matrix_login <homeserver_url> <user_id> <password>
        Login and get access token via Matrix Client API
        Example: matrix_login "https://matrix.example.com" "@bot:example.com" "secret123"

    matrix_create_room <homeserver_url> <access_token> <room_name> [room_alias] [is_public]
        Create a new Matrix room
        Example: matrix_create_room "https://matrix.example.com" "syt_..." "My Room" "myroom" "false"

    matrix_invite_user <homeserver_url> <access_token> <room_id> <user_id>
        Invite a user to a room
        Example: matrix_invite_user "https://matrix.example.com" "syt_..." "!abc:example.com" "@user:example.com"

SETUP:
    1. Create a Matrix bot account on your homeserver
    2. Run: matrix-dispatch-helper.sh setup
    3. Map rooms: matrix-dispatch-helper.sh map '!room:server' runner-name
    4. Start: matrix-dispatch-helper.sh start --daemon

MATRIX USAGE:
    In a mapped room, type:
        !ai Review the auth module for security issues
        !ai Generate unit tests for src/utils/

    The bot prefix (!ai) is configurable in setup.

ARCHITECTURE:
    Matrix Room → Bot receives message → Lookup room-to-runner mapping
    → Dispatch to runner via runner-helper.sh → Post response back to room

    ┌──────────────┐     ┌──────────────┐     ┌──────────────────┐
    │ Matrix Room   │────▶│ Matrix Bot   │────▶│ runner-helper.sh │
    │ !ai prompt    │     │ (Node.js)    │     │ → OpenCode       │
    │               │◀────│              │◀────│                  │
    │ AI response   │     │              │     │                  │
    └──────────────┘     └──────────────┘     └──────────────────┘

AUTO-SETUP (Cloudron + Synapse):
    Fully automated provisioning — installs Synapse, creates bot user,
    obtains access token, configures the bot, creates rooms, and maps runners.

    matrix-dispatch-helper.sh auto-setup <cloudron-server> [options]

    Options:
      --subdomain <name>     Synapse subdomain (default: matrix)
      --bot-user <name>      Bot username (default: aibot)
      --bot-display <name>   Bot display name (default: AI DevOps Bot)
      --runners <list>       Comma-separated runner names for room creation
      --allowed-users <list> Comma-separated allowed Matrix user IDs
      --dry-run              Show plan without executing
      --skip-install         Skip Synapse installation (already installed)
      --admin-token <token>  Use existing Synapse admin token

    Prerequisites:
      - Cloudron server configured in configs/cloudron-config.json
      - Cloudron API token set for the server
      - Synapse admin token stored via: aidevops secret set SYNAPSE_ADMIN_TOKEN_<server>

    Example:
      matrix-dispatch-helper.sh auto-setup cloudron01 \
        --runners code-reviewer,seo-analyst,ops-monitor \
        --allowed-users @admin:example.com

MANUAL CLOUDRON SETUP:
    1. Install Synapse on Cloudron (Matrix homeserver)
    2. Create bot user via Synapse Admin Console
    3. Login as bot via Element to get access token
    4. Run setup wizard with homeserver URL and token
    5. Invite bot to rooms, then map rooms to runners

REQUIREMENTS:
    - Node.js >= 18 (for matrix-bot-sdk)
    - jq (brew install jq)
    - OpenCode server running (opencode serve)
    - Matrix homeserver with bot account
    - runner-helper.sh (for runner dispatch)

CONFIGURATION:
    Config: ~/.config/aidevops/matrix-bot.json
    Data:   ~/.aidevops/.agent-workspace/matrix-bot/
    Logs:   ~/.aidevops/.agent-workspace/matrix-bot/logs/

EXAMPLES:
    # Automated setup (recommended)
    matrix-dispatch-helper.sh auto-setup cloudron01 \
      --runners code-reviewer,seo-analyst,ops-monitor \
      --allowed-users @admin:example.com

    # Dry run (preview without executing)
    matrix-dispatch-helper.sh auto-setup cloudron01 --dry-run

    # Manual setup flow
    matrix-dispatch-helper.sh setup
    runner-helper.sh create code-reviewer --description "Code review bot"
    matrix-dispatch-helper.sh map '!abc:matrix.example.com' code-reviewer
    matrix-dispatch-helper.sh start --daemon

    # Multiple rooms, different runners
    matrix-dispatch-helper.sh map '!dev:server' code-reviewer
    matrix-dispatch-helper.sh map '!seo:server' seo-analyst
    matrix-dispatch-helper.sh map '!ops:server' ops-monitor

    # Test without Matrix
    matrix-dispatch-helper.sh test code-reviewer "Review src/auth.ts"

EOF
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	setup) cmd_setup "$@" ;;
	auto-setup) cmd_auto_setup "$@" ;;
	start) cmd_start "$@" ;;
	stop) cmd_stop "$@" ;;
	status) cmd_status "$@" ;;
	map) cmd_map "$@" ;;
	unmap) cmd_unmap "$@" ;;
	mappings) cmd_mappings "$@" ;;
	sessions) cmd_sessions "$@" ;;
	test) cmd_test "$@" ;;
	logs) cmd_logs "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
