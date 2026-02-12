#!/usr/bin/env bash
# matrix-dispatch-helper.sh - Matrix bot for dispatching messages to AI runners
#
# Bridges Matrix chat rooms to aidevops runners via OpenCode server.
# Each Matrix room maps to a named runner. Messages in the room become
# prompts dispatched to the runner, with responses posted back.
#
# Usage:
#   matrix-dispatch-helper.sh setup                    # Interactive setup wizard
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
readonly RUNNER_HELPER="$HOME/.aidevops/agents/scripts/runner-helper.sh"
readonly OPENCODE_PORT="${OPENCODE_PORT:-4096}"
readonly OPENCODE_HOST="${OPENCODE_HOST:-127.0.0.1}"

readonly BOLD='\033[1m'

#######################################
# Logging
#######################################
log_info() { echo -e "${BLUE}[MATRIX]${NC} $*"; }
log_success() { echo -e "${GREEN}[MATRIX]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[MATRIX]${NC} $*"; }
log_error() { echo -e "${RED}[MATRIX]${NC} $*" >&2; }

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
	check_deps || return 1
	ensure_dirs

	echo -e "${BOLD}Matrix Bot Setup${NC}"
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
            maxPromptLength: 4000,
            responseTimeout: 600,
            sessionIdleTimeout: $sessionIdleTimeout
        }' --jsonargs < <(if [[ -f "$CONFIG_FILE" ]]; then cat "$CONFIG_FILE"; else echo '{}'; fi) >"$temp_file"
	mv "$temp_file" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE"

	# Install matrix-bot-sdk and better-sqlite3 if needed
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
			echo "Install manually: npm install --prefix $DATA_DIR matrix-bot-sdk better-sqlite3"
			return 1
		}
		log_success "Dependencies installed"
	fi

	# Generate session store and bot scripts
	generate_session_store_script
	generate_bot_script

	echo ""
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

	return 0
}

#######################################
# Generate the session store module
#######################################
generate_session_store_script() {
	cat >"$SESSION_STORE_SCRIPT" <<'SESSIONSCRIPT'
// session-store.mjs - SQLite session store for per-channel conversation persistence
// Generated by matrix-dispatch-helper.sh
// Do not edit directly - regenerate with: matrix-dispatch-helper.sh setup

import Database from "better-sqlite3";
import { mkdirSync } from "fs";
import { dirname } from "path";

const DB_PATH = process.env.MATRIX_SESSION_DB ||
    `${process.env.HOME}/.aidevops/.agent-workspace/matrix-bot/sessions.db`;

let _db = null;

/**
 * Get or create the database connection with WAL mode and schema.
 */
function getDb() {
    if (_db) return _db;

    mkdirSync(dirname(DB_PATH), { recursive: true });

    _db = new Database(DB_PATH);
    _db.pragma("journal_mode = WAL");
    _db.pragma("busy_timeout = 5000");

    _db.exec(`
        CREATE TABLE IF NOT EXISTS sessions (
            room_id          TEXT PRIMARY KEY,
            session_id       TEXT,
            compacted_context TEXT DEFAULT '',
            message_count    INTEGER DEFAULT 0,
            created_at       TEXT DEFAULT (datetime('now')),
            last_active      TEXT DEFAULT (datetime('now')),
            runner_name      TEXT DEFAULT ''
        );

        CREATE TABLE IF NOT EXISTS message_log (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            room_id     TEXT NOT NULL,
            role        TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
            content     TEXT NOT NULL,
            sender      TEXT DEFAULT '',
            created_at  TEXT DEFAULT (datetime('now')),
            FOREIGN KEY (room_id) REFERENCES sessions(room_id)
        );

        CREATE INDEX IF NOT EXISTS idx_message_log_room
            ON message_log(room_id, created_at);

        CREATE INDEX IF NOT EXISTS idx_sessions_last_active
            ON sessions(last_active);
    `);

    return _db;
}

/**
 * Get or create a session for a room. Returns session record.
 */
export function getSession(roomId, runnerName) {
    const db = getDb();

    let session = db.prepare(
        "SELECT * FROM sessions WHERE room_id = ?"
    ).get(roomId);

    if (!session) {
        db.prepare(`
            INSERT INTO sessions (room_id, runner_name, session_id)
            VALUES (?, ?, ?)
        `).run(roomId, runnerName, "");

        session = db.prepare(
            "SELECT * FROM sessions WHERE room_id = ?"
        ).get(roomId);
    }

    return session;
}

/**
 * Update session_id (the upstream AI session ID) for a room.
 */
export function setSessionId(roomId, sessionId) {
    const db = getDb();
    db.prepare(`
        UPDATE sessions
        SET session_id = ?, last_active = datetime('now')
        WHERE room_id = ?
    `).run(sessionId, roomId);
}

/**
 * Record a message in the log and bump the session activity.
 */
export function addMessage(roomId, role, content, sender = "") {
    const db = getDb();

    db.prepare(`
        INSERT INTO message_log (room_id, role, content, sender)
        VALUES (?, ?, ?, ?)
    `).run(roomId, role, content, sender);

    db.prepare(`
        UPDATE sessions
        SET message_count = message_count + 1,
            last_active = datetime('now')
        WHERE room_id = ?
    `).run(roomId);
}

/**
 * Get recent messages for a room (for building compaction context).
 */
export function getRecentMessages(roomId, limit = 50) {
    const db = getDb();
    return db.prepare(`
        SELECT role, content, sender, created_at
        FROM message_log
        WHERE room_id = ?
        ORDER BY created_at DESC
        LIMIT ?
    `).all(roomId, limit).reverse();
}

/**
 * Store compacted context for a room and clear old messages.
 * This is the key operation: summarise the conversation, store it,
 * then prune the detailed message log.
 */
export function compactSession(roomId, compactedContext) {
    const db = getDb();

    const compact = db.transaction(() => {
        // Store the compacted summary
        db.prepare(`
            UPDATE sessions
            SET compacted_context = ?,
                session_id = '',
                message_count = 0,
                last_active = datetime('now')
            WHERE room_id = ?
        `).run(compactedContext, roomId);

        // Prune message log for this room (keep nothing — context is compacted)
        db.prepare(
            "DELETE FROM message_log WHERE room_id = ?"
        ).run(roomId);
    });

    compact();
}

/**
 * Get the compacted context for a room (to prime new sessions).
 */
export function getCompactedContext(roomId) {
    const db = getDb();
    const row = db.prepare(
        "SELECT compacted_context FROM sessions WHERE room_id = ?"
    ).get(roomId);
    return row?.compacted_context || "";
}

/**
 * Find sessions that have been idle longer than the given seconds.
 * Returns rooms that need compaction.
 */
export function getIdleSessions(idleSeconds) {
    const db = getDb();
    return db.prepare(`
        SELECT room_id, session_id, runner_name, message_count, last_active
        FROM sessions
        WHERE session_id != ''
          AND message_count > 0
          AND datetime(last_active, '+' || ? || ' seconds') < datetime('now')
    `).all(idleSeconds);
}

/**
 * Clear a session entirely (for manual cleanup).
 */
export function clearSession(roomId) {
    const db = getDb();

    const clear = db.transaction(() => {
        db.prepare("DELETE FROM message_log WHERE room_id = ?").run(roomId);
        db.prepare("DELETE FROM sessions WHERE room_id = ?").run(roomId);
    });

    clear();
}

/**
 * List all sessions with stats.
 */
export function listSessions() {
    const db = getDb();
    return db.prepare(`
        SELECT room_id, session_id, runner_name, message_count,
               length(compacted_context) AS context_bytes,
               created_at, last_active
        FROM sessions
        ORDER BY last_active DESC
    `).all();
}

/**
 * Get database stats.
 */
export function getStats() {
    const db = getDb();

    const sessionCount = db.prepare(
        "SELECT COUNT(*) AS count FROM sessions"
    ).get().count;

    const activeCount = db.prepare(
        "SELECT COUNT(*) AS count FROM sessions WHERE session_id != ''"
    ).get().count;

    const messageCount = db.prepare(
        "SELECT COUNT(*) AS count FROM message_log"
    ).get().count;

    const contextBytes = db.prepare(
        "SELECT COALESCE(SUM(length(compacted_context)), 0) AS total FROM sessions"
    ).get().total;

    return { sessionCount, activeCount, messageCount, contextBytes };
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
// matrix-dispatch-bot.mjs - Matrix bot that dispatches to AI runners
// Generated by matrix-dispatch-helper.sh
// Do not edit directly - regenerate with: matrix-dispatch-helper.sh setup

import { MatrixClient, SimpleFsStorageProvider, AutojoinRoomsMixin } from "matrix-bot-sdk";
import { readFileSync } from "fs";
import { spawn } from "child_process";
import * as store from "./session-store.mjs";

const CONFIG_PATH = process.env.MATRIX_BOT_CONFIG || `${process.env.HOME}/.config/aidevops/matrix-bot.json`;
const RUNNER_HELPER = `${process.env.HOME}/.aidevops/agents/scripts/runner-helper.sh`;
const OPENCODE_HOST = process.env.OPENCODE_HOST || "127.0.0.1";
const OPENCODE_PORT = process.env.OPENCODE_PORT || "4096";

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

// Build the full prompt with conversation context for a room
function buildContextualPrompt(roomId, newPrompt) {
    const compacted = store.getCompactedContext(roomId);
    const recent = store.getRecentMessages(roomId, 20);

    const parts = [];

    if (compacted) {
        parts.push(
            "[Previous conversation summary]\n" + compacted + "\n[End summary]\n"
        );
    }

    if (recent.length > 0) {
        parts.push("[Recent messages]");
        for (const msg of recent) {
            const label = msg.role === "user" ? msg.sender || "User" : "Assistant";
            parts.push(`${label}: ${msg.content}`);
        }
        parts.push("[End recent messages]\n");
    }

    parts.push(newPrompt);
    return parts.join("\n");
}

// Build a compaction prompt from the conversation history
function buildCompactionPrompt(roomId) {
    const compacted = store.getCompactedContext(roomId);
    const messages = store.getRecentMessages(roomId, 50);

    if (messages.length === 0 && !compacted) return null;

    const parts = [];
    parts.push("Summarise the following conversation into a concise context summary.");
    parts.push("Preserve: key decisions, facts established, user preferences, and any ongoing tasks.");
    parts.push("Omit: greetings, filler, and resolved questions.");
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

// Compact idle sessions: summarise context, store it, destroy upstream session
async function compactIdleSessions(config) {
    const idleTimeout = config.sessionIdleTimeout || 300;
    const idleSessions = store.getIdleSessions(idleTimeout);

    for (const session of idleSessions) {
        console.log(`[MATRIX-BOT] Compacting idle session for room ${session.room_id} (${session.message_count} messages, idle since ${session.last_active})`);

        try {
            const compactionPrompt = buildCompactionPrompt(session.room_id);
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

            // Store the compacted summary and clear message log
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
    console.log(`[MATRIX-BOT] Session idle timeout: ${idleTimeout}s`);

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
            store.getSession(roomId, runnerName);

            // Record the user message
            store.addMessage(roomId, "user", prompt, event.sender);

            // Build contextual prompt (includes compacted history + recent messages)
            const contextualPrompt = buildContextualPrompt(roomId, prompt);

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

            // Record the assistant response
            store.addMessage(roomId, "assistant", response);

            // Truncate and send response
            const truncated = truncateResponse(response, config.maxPromptLength || 4000);
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

	# Session store
	if [[ -f "$SESSION_DB" ]] && command -v sqlite3 &>/dev/null; then
		local total_sessions active_sessions
		total_sessions=$(sqlite3 -cmd ".timeout 5000" "$SESSION_DB" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "0")
		active_sessions=$(sqlite3 -cmd ".timeout 5000" "$SESSION_DB" "SELECT COUNT(*) FROM sessions WHERE session_id != '';" 2>/dev/null || echo "0")
		echo "Sessions: ${total_sessions} total, ${active_sessions} active"
		echo "Session DB: $SESSION_DB"
	else
		echo "Sessions: (no database yet)"
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

	case "$subcmd" in
	list)
		echo -e "${BOLD}Conversation Sessions${NC}"
		echo "──────────────────────────────────"

		if [[ ! -f "$SESSION_DB" ]]; then
			echo "(no sessions — database not yet created)"
			echo "Sessions are created automatically when the bot processes messages."
			return 0
		fi

		local sessions
		sessions=$(sqlite3 -cmd ".timeout 5000" -separator '|' "$SESSION_DB" \
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
		;;

	clear)
		local room_id="${1:-}"
		if [[ -z "$room_id" ]]; then
			log_error "Room ID required"
			echo "Usage: matrix-dispatch-helper.sh sessions clear '<room_id>'"
			return 1
		fi

		if [[ ! -f "$SESSION_DB" ]]; then
			log_info "No session database"
			return 0
		fi

		sqlite3 -cmd ".timeout 5000" "$SESSION_DB" \
			"DELETE FROM message_log WHERE room_id = '$room_id'; DELETE FROM sessions WHERE room_id = '$room_id';" 2>/dev/null
		log_success "Cleared session for room $room_id"
		;;

	clear-all)
		if [[ ! -f "$SESSION_DB" ]]; then
			log_info "No session database"
			return 0
		fi

		sqlite3 -cmd ".timeout 5000" "$SESSION_DB" \
			"DELETE FROM message_log; DELETE FROM sessions;" 2>/dev/null
		log_success "Cleared all sessions"
		;;

	stats)
		if [[ ! -f "$SESSION_DB" ]]; then
			echo "No session database"
			return 0
		fi

		echo -e "${BOLD}Session Statistics${NC}"
		echo "──────────────────────────────────"

		local total_sessions active_sessions total_messages context_bytes db_size
		total_sessions=$(sqlite3 -cmd ".timeout 5000" "$SESSION_DB" "SELECT COUNT(*) FROM sessions;" 2>/dev/null)
		active_sessions=$(sqlite3 -cmd ".timeout 5000" "$SESSION_DB" "SELECT COUNT(*) FROM sessions WHERE session_id != '';" 2>/dev/null)
		total_messages=$(sqlite3 -cmd ".timeout 5000" "$SESSION_DB" "SELECT COUNT(*) FROM message_log;" 2>/dev/null)
		context_bytes=$(sqlite3 -cmd ".timeout 5000" "$SESSION_DB" "SELECT COALESCE(SUM(length(compacted_context)), 0) FROM sessions;" 2>/dev/null)
		db_size=$(stat -f%z "$SESSION_DB" 2>/dev/null || stat -c%s "$SESSION_DB" 2>/dev/null || echo "0")

		echo "Total sessions:    ${total_sessions:-0}"
		echo "Active sessions:   ${active_sessions:-0}"
		echo "Messages in log:   ${total_messages:-0}"
		echo "Compacted context: $((${context_bytes:-0} / 1024))KB"
		echo "Database size:     $((${db_size:-0} / 1024))KB"
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
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
matrix-dispatch-helper.sh - Matrix bot for AI runner dispatch

USAGE:
    matrix-dispatch-helper.sh <command> [options]

COMMANDS:
    setup                       Interactive setup wizard
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

CLOUDRON SETUP:
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
    # Full setup flow
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
