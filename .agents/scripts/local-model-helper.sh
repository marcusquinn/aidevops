#!/usr/bin/env bash
# shellcheck disable=SC1091

# Local Model Helper - llama.cpp inference management for aidevops
# Hardware-aware setup, HuggingFace GGUF model management, usage tracking,
# disk cleanup, and OpenAI-compatible local server management.
#
# Usage: local-model-helper.sh [command] [options]
#
# Commands:
#   install [--update]            Install/update llama.cpp + huggingface-cli (alias: setup)
#   serve [--model M] [options]   Start llama-server localhost:8080 (alias: start)
#   stop                          Stop running llama-server
#   status                        Show server status and loaded model
#   models                        List downloaded GGUF models with size/last-used
#   search <query>                Search HuggingFace for GGUF models
#   pull <repo> [--quant Q]       Download a GGUF model from HuggingFace (alias: download)
#   recommend                     Hardware-aware model recommendations
#   usage [--since DATE] [--json] Show usage statistics (SQLite)
#   cleanup [--remove-stale]      Show/remove stale models (>30d threshold)
#   update                        Check for new llama.cpp release
#   inventory [--json] [--sync]   Show model inventory from database
#   nudge [--json]                Session-start stale model check (>5 GB)
#   benchmark --model M           Benchmark a model on local hardware
#   help                          Show this help
#
# Options:
#   --port N        Server port (default: 8080)
#   --ctx-size N    Context window size (default: 8192)
#   --threads N     CPU threads (default: auto-detect performance cores)
#   --gpu-layers N  GPU layers to offload (default: 99 = all)
#   --json          Output in JSON format
#   --quiet         Suppress informational output
#
# Integration:
#   - OpenAI-compatible API at http://localhost:<port>/v1
#   - model-availability-helper.sh check local → exit 0 if server running
#   - Usage tracked in SQLite at ~/.aidevops/.agent-workspace/memory/local-models.db
#   - Tables: model_usage (per-request), model_inventory (downloaded models)
#   - Session-start nudge: `nudge` command checks stale models > 5 GB
#   - See tools/local-models/local-models.md for full documentation
#
# Exit codes:
#   0 - Success
#   1 - General error
#   2 - Dependency missing (llama.cpp, huggingface-cli)
#   3 - Model not found
#   4 - Server already running / not running
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# =============================================================================
# Configuration
# =============================================================================

readonly LOCAL_MODELS_DIR="${HOME}/.aidevops/local-models"
readonly LOCAL_BIN_DIR="${LOCAL_MODELS_DIR}/bin"
readonly LOCAL_MODELS_STORE="${LOCAL_MODELS_DIR}/models"
readonly LOCAL_CONFIG_FILE="${LOCAL_MODELS_DIR}/config.json"
readonly LOCAL_PID_FILE="${LOCAL_MODELS_DIR}/llama-server.pid"
readonly LLAMA_SERVER_BIN="${LOCAL_BIN_DIR}/llama-server"
readonly LLAMA_CLI_BIN="${LOCAL_BIN_DIR}/llama-cli"

# Usage/inventory database (t1338.5) — stored with other framework SQLite DBs
readonly LOCAL_MODELS_DB_DIR="${HOME}/.aidevops/.agent-workspace/memory"
readonly LOCAL_USAGE_DB="${LOCAL_MODELS_DB_DIR}/local-models.db"
# Legacy DB path for migration
readonly LOCAL_USAGE_DB_LEGACY="${LOCAL_MODELS_DIR}/usage.db"

# Stale model nudge threshold (bytes) — 5 GB
readonly STALE_NUDGE_THRESHOLD_BYTES=5368709120

# Defaults (overridable via config.json or CLI flags)
# Prefixed with LLAMA_ to avoid collision with shared-constants.sh readonly LLAMA_PORT
LLAMA_PORT=8080
LLAMA_HOST="127.0.0.1"
LLAMA_CTX_SIZE=8192
LLAMA_GPU_LAYERS=99
LLAMA_FLASH_ATTN="true"
STALE_THRESHOLD_DAYS=30

# GitHub release API for llama.cpp
readonly LLAMA_CPP_REPO="ggml-org/llama.cpp"
readonly LLAMA_CPP_API="https://api.github.com/repos/${LLAMA_CPP_REPO}/releases/latest"

# HuggingFace API
readonly HF_API="https://huggingface.co/api"

# =============================================================================
# Utility Functions
# =============================================================================

# Escape single quotes for safe SQL string interpolation
# Usage: sqlite3 "$db" "SELECT * FROM t WHERE col = '$(sql_escape "$val")';"
sql_escape() {
	local val="$1"
	printf '%s' "${val//\'/\'\'}"
	return 0
}

# Sanitize a value for use as a bare (unquoted) SQL integer.
# Returns the value if it matches an integer pattern, otherwise returns the
# provided default (or 0).  This prevents SQL injection via numeric parameters.
# Usage: sqlite3 "$db" "INSERT INTO t (col) VALUES ($(sql_int "$val"));"
sql_int() {
	local val="$1"
	local default="${2:-0}"
	if [[ "$val" =~ ^-?[0-9]+$ ]]; then
		printf '%s' "$val"
	else
		printf '%s' "$default"
	fi
	return 0
}

# Sanitize a value for use as a bare (unquoted) SQL real/float.
# Returns the value if it matches a numeric pattern, otherwise returns the
# provided default (or 0.0).
sql_real() {
	local val="$1"
	local default="${2:-0.0}"
	if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
		printf '%s' "$val"
	else
		printf '%s' "$default"
	fi
	return 0
}

# Ensure the local-models directory structure exists
ensure_dirs() {
	mkdir -p "$LOCAL_BIN_DIR" 2>/dev/null || true
	mkdir -p "$LOCAL_MODELS_STORE" 2>/dev/null || true
	mkdir -p "$LOCAL_MODELS_DB_DIR" 2>/dev/null || true
	return 0
}

# Load config.json defaults if present
load_config() {
	if [[ -f "$LOCAL_CONFIG_FILE" ]] && suppress_stderr command -v jq; then
		LLAMA_PORT="$(jq -r '.port // 8080' "$LOCAL_CONFIG_FILE" 2>/dev/null || echo "8080")"
		LLAMA_HOST="$(jq -r '.host // "127.0.0.1"' "$LOCAL_CONFIG_FILE" 2>/dev/null || echo "127.0.0.1")"
		LLAMA_CTX_SIZE="$(jq -r '.ctx_size // 8192' "$LOCAL_CONFIG_FILE" 2>/dev/null || echo "8192")"
		LLAMA_GPU_LAYERS="$(jq -r '.gpu_layers // 99' "$LOCAL_CONFIG_FILE" 2>/dev/null || echo "99")"
		LLAMA_FLASH_ATTN="$(jq -r '.flash_attn // true' "$LOCAL_CONFIG_FILE" 2>/dev/null || echo "true")"
	fi
	return 0
}

# Write default config.json if it doesn't exist
write_default_config() {
	if [[ ! -f "$LOCAL_CONFIG_FILE" ]]; then
		cat >"$LOCAL_CONFIG_FILE" <<-'CONFIGEOF'
			{
			  "port": 8080,
			  "host": "127.0.0.1",
			  "ctx_size": 8192,
			  "threads": "auto",
			  "gpu_layers": 99,
			  "flash_attn": true
			}
		CONFIGEOF
		print_info "Created default config at ${LOCAL_CONFIG_FILE}"
	fi
	return 0
}

# Detect platform and architecture
detect_platform() {
	local os arch platform
	os="$(uname -s)"
	arch="$(uname -m)"

	case "$os" in
	Darwin)
		case "$arch" in
		arm64) platform="macos-arm64" ;;
		x86_64) platform="macos-x64" ;;
		*)
			print_error "Unsupported macOS architecture: ${arch}"
			return 1
			;;
		esac
		;;
	Linux)
		case "$arch" in
		x86_64)
			# Check for GPU acceleration (order: ROCm > Vulkan > NVIDIA-via-Vulkan > CPU)
			if suppress_stderr command -v rocminfo; then
				platform="linux-rocm"
			elif suppress_stderr command -v vulkaninfo; then
				platform="linux-vulkan"
			elif suppress_stderr command -v nvidia-smi; then
				# NVIDIA GPU detected but no Vulkan SDK — use Vulkan binary anyway
				# (NVIDIA drivers include Vulkan support; vulkaninfo just isn't installed)
				platform="linux-vulkan"
			else
				platform="linux-x64"
			fi
			;;
		aarch64)
			print_error "No prebuilt Linux ARM64 binary available. Compile from source:"
			print_error "  git clone https://github.com/ggml-org/llama.cpp.git"
			print_error "  cd llama.cpp && cmake -B build && cmake --build build --config Release -j\$(nproc)"
			return 1
			;;
		*)
			print_error "Unsupported Linux architecture: ${arch}"
			return 1
			;;
		esac
		;;
	*)
		print_error "${ERROR_UNKNOWN_PLATFORM}: ${os}"
		return 1
		;;
	esac

	echo "$platform"
	return 0
}

# Detect number of performance cores (not efficiency cores on Apple Silicon)
detect_threads() {
	local threads
	if [[ "$(uname -s)" == "Darwin" ]]; then
		threads="$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "4")"
	else
		threads="$(nproc 2>/dev/null || echo "4")"
	fi
	echo "$threads"
	return 0
}

# Detect available memory in GB (for model recommendations)
detect_available_memory_gb() {
	local mem_gb
	if [[ "$(uname -s)" == "Darwin" ]]; then
		local mem_bytes
		mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo "0")"
		mem_gb="$((mem_bytes / 1073741824))"
	else
		local mem_kb
		mem_kb="$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")"
		mem_gb="$((mem_kb / 1048576))"
	fi
	echo "$mem_gb"
	return 0
}

# Detect GPU type
detect_gpu() {
	local os
	os="$(uname -s)"
	if [[ "$os" == "Darwin" ]]; then
		local chip
		chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")"
		if [[ "$(uname -m)" == "arm64" ]]; then
			echo "Metal (Apple Silicon - ${chip})"
		else
			echo "Metal (Intel Mac - ${chip})"
		fi
	elif suppress_stderr command -v nvidia-smi; then
		nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1
	elif suppress_stderr command -v rocminfo; then
		echo "ROCm (AMD)"
	elif suppress_stderr command -v vulkaninfo; then
		echo "Vulkan"
	else
		echo "CPU only (no GPU detected)"
	fi
	return 0
}

# Initialize the usage tracking SQLite database (t1338.5)
# Schema: model_usage (per-request logging with session ID),
#          model_inventory (downloaded models with size tracking)
init_usage_db() {
	if ! suppress_stderr command -v sqlite3; then
		print_warning "sqlite3 not found — usage tracking disabled"
		return 0
	fi

	ensure_dirs

	# Migrate from legacy DB path if it exists and new one doesn't
	if [[ -f "$LOCAL_USAGE_DB_LEGACY" ]] && [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		_migrate_legacy_db
	fi

	if [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		log_stderr "init_usage_db" sqlite3 "$LOCAL_USAGE_DB" <<-'SQLEOF'
			CREATE TABLE IF NOT EXISTS model_usage (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				model TEXT NOT NULL,
				session_id TEXT DEFAULT '',
				timestamp TEXT NOT NULL DEFAULT (datetime('now')),
				tokens_in INTEGER DEFAULT 0,
				tokens_out INTEGER DEFAULT 0,
				duration_ms INTEGER DEFAULT 0,
				tok_per_sec REAL DEFAULT 0.0
			);
			CREATE TABLE IF NOT EXISTS model_inventory (
				model TEXT PRIMARY KEY,
				file_path TEXT NOT NULL DEFAULT '',
				repo_source TEXT DEFAULT '',
				size_bytes INTEGER DEFAULT 0,
				quantization TEXT DEFAULT '',
				first_seen TEXT NOT NULL DEFAULT (datetime('now')),
				last_used TEXT NOT NULL DEFAULT (datetime('now')),
				total_requests INTEGER DEFAULT 0
			);
			CREATE INDEX IF NOT EXISTS idx_model_usage_model ON model_usage(model);
			CREATE INDEX IF NOT EXISTS idx_model_usage_timestamp ON model_usage(timestamp);
			CREATE INDEX IF NOT EXISTS idx_model_usage_session ON model_usage(session_id);
			CREATE INDEX IF NOT EXISTS idx_model_inventory_last_used ON model_inventory(last_used);
		SQLEOF
		print_info "Initialized usage database at ${LOCAL_USAGE_DB}"
	else
		# Ensure schema is up to date (idempotent migrations)
		_ensure_schema_current
	fi
	return 0
}

# Migrate legacy usage.db (old path, old table names) to new location/schema
_migrate_legacy_db() {
	local legacy_db="$LOCAL_USAGE_DB_LEGACY"
	local migration_failed=false
	print_info "Migrating legacy usage database to ${LOCAL_USAGE_DB}..."

	# Backup the legacy DB before migration
	backup_sqlite_db "$legacy_db" "pre-migrate-t1338.5" >/dev/null 2>&1 || true

	# Create new DB with new schema
	if ! log_stderr "migrate_legacy_db" sqlite3 "$LOCAL_USAGE_DB" <<-'SQLEOF'; then
		CREATE TABLE IF NOT EXISTS model_usage (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			model TEXT NOT NULL,
			session_id TEXT DEFAULT '',
			timestamp TEXT NOT NULL DEFAULT (datetime('now')),
			tokens_in INTEGER DEFAULT 0,
			tokens_out INTEGER DEFAULT 0,
			duration_ms INTEGER DEFAULT 0,
			tok_per_sec REAL DEFAULT 0.0
		);
		CREATE TABLE IF NOT EXISTS model_inventory (
			model TEXT PRIMARY KEY,
			file_path TEXT NOT NULL DEFAULT '',
			repo_source TEXT DEFAULT '',
			size_bytes INTEGER DEFAULT 0,
			quantization TEXT DEFAULT '',
			first_seen TEXT NOT NULL DEFAULT (datetime('now')),
			last_used TEXT NOT NULL DEFAULT (datetime('now')),
			total_requests INTEGER DEFAULT 0
		);
		CREATE INDEX IF NOT EXISTS idx_model_usage_model ON model_usage(model);
		CREATE INDEX IF NOT EXISTS idx_model_usage_timestamp ON model_usage(timestamp);
		CREATE INDEX IF NOT EXISTS idx_model_usage_session ON model_usage(session_id);
		CREATE INDEX IF NOT EXISTS idx_model_inventory_last_used ON model_inventory(last_used);
	SQLEOF
		print_error "Failed to create new schema during migration"
		return 1
	fi

	# Copy data from legacy tables if they exist
	local has_usage has_model_access
	has_usage="$(sqlite3 "$legacy_db" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='usage';" 2>/dev/null || echo "0")"
	has_model_access="$(sqlite3 "$legacy_db" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='model_access';" 2>/dev/null || echo "0")"

	if [[ "$has_usage" == "1" ]]; then
		# Use ATTACH DATABASE with explicit column mapping to avoid schema mismatch
		if log_stderr "migrate_usage_rows" sqlite3 "$LOCAL_USAGE_DB" <<-SQLEOF; then
			ATTACH DATABASE '$(sql_escape "$legacy_db")' AS legacy;
			INSERT OR IGNORE INTO model_usage (model, session_id, timestamp, tokens_in, tokens_out, duration_ms, tok_per_sec)
			SELECT model, '', timestamp, tokens_in, tokens_out, duration_ms, tok_per_sec
			FROM legacy.usage;
			DETACH DATABASE legacy;
		SQLEOF
			print_info "Migrated usage records to model_usage"
		else
			print_error "Failed to migrate usage records — legacy DB preserved"
			migration_failed=true
		fi
	fi

	if [[ "$has_model_access" == "1" ]]; then
		# Use ATTACH DATABASE with explicit column mapping for model_access -> model_inventory
		if log_stderr "migrate_model_access_rows" sqlite3 "$LOCAL_USAGE_DB" <<-SQLEOF; then
			ATTACH DATABASE '$(sql_escape "$legacy_db")' AS legacy;
			INSERT OR IGNORE INTO model_inventory (model, first_seen, last_used, total_requests)
			SELECT model, first_used, last_used, total_requests
			FROM legacy.model_access;
			DETACH DATABASE legacy;
		SQLEOF
			print_info "Migrated model_access records to model_inventory"
		else
			print_error "Failed to migrate model_access records — legacy DB preserved"
			migration_failed=true
		fi
	fi

	if [[ "$migration_failed" == "true" ]]; then
		print_error "Migration partially failed. Legacy DB preserved at ${legacy_db}"
		return 1
	fi

	print_success "Migration complete. Legacy DB preserved at ${legacy_db}"
	return 0
}

# Ensure schema is current (add missing columns/tables idempotently)
_ensure_schema_current() {
	# Check if model_usage table exists (might be old schema with 'usage' table)
	local has_model_usage has_model_inventory
	has_model_usage="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='model_usage';" 2>/dev/null || echo "0")"
	has_model_inventory="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='model_inventory';" 2>/dev/null || echo "0")"

	if [[ "$has_model_usage" == "0" ]]; then
		# Create model_usage table
		log_stderr "ensure_schema_usage" sqlite3 "$LOCAL_USAGE_DB" <<-'SQLEOF'
			CREATE TABLE IF NOT EXISTS model_usage (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				model TEXT NOT NULL,
				session_id TEXT DEFAULT '',
				timestamp TEXT NOT NULL DEFAULT (datetime('now')),
				tokens_in INTEGER DEFAULT 0,
				tokens_out INTEGER DEFAULT 0,
				duration_ms INTEGER DEFAULT 0,
				tok_per_sec REAL DEFAULT 0.0
			);
			CREATE INDEX IF NOT EXISTS idx_model_usage_model ON model_usage(model);
			CREATE INDEX IF NOT EXISTS idx_model_usage_timestamp ON model_usage(timestamp);
			CREATE INDEX IF NOT EXISTS idx_model_usage_session ON model_usage(session_id);
		SQLEOF

		# Migrate from legacy 'usage' table if it exists (check separately to avoid prepare-time errors)
		local has_legacy_usage
		has_legacy_usage="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='usage';" 2>/dev/null || echo "0")"
		if [[ "$has_legacy_usage" == "1" ]]; then
			sqlite3 "$LOCAL_USAGE_DB" "INSERT OR IGNORE INTO model_usage (model, session_id, timestamp, tokens_in, tokens_out, duration_ms, tok_per_sec) SELECT model, '', timestamp, tokens_in, tokens_out, duration_ms, tok_per_sec FROM usage;" 2>/dev/null || true
		fi
	fi

	if [[ "$has_model_inventory" == "0" ]]; then
		# Create model_inventory table
		log_stderr "ensure_schema_inventory" sqlite3 "$LOCAL_USAGE_DB" <<-'SQLEOF'
			CREATE TABLE IF NOT EXISTS model_inventory (
				model TEXT PRIMARY KEY,
				file_path TEXT NOT NULL DEFAULT '',
				repo_source TEXT DEFAULT '',
				size_bytes INTEGER DEFAULT 0,
				quantization TEXT DEFAULT '',
				first_seen TEXT NOT NULL DEFAULT (datetime('now')),
				last_used TEXT NOT NULL DEFAULT (datetime('now')),
				total_requests INTEGER DEFAULT 0
			);
			CREATE INDEX IF NOT EXISTS idx_model_inventory_last_used ON model_inventory(last_used);
		SQLEOF

		# Migrate from legacy 'model_access' table if it exists
		local has_legacy_access
		has_legacy_access="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='model_access';" 2>/dev/null || echo "0")"
		if [[ "$has_legacy_access" == "1" ]]; then
			sqlite3 "$LOCAL_USAGE_DB" "INSERT OR IGNORE INTO model_inventory (model, first_seen, last_used, total_requests) SELECT model, first_used, last_used, total_requests FROM model_access;" 2>/dev/null || true
		fi
	fi

	# Column-level drift detection: add missing columns idempotently.
	# Each ALTER TABLE is wrapped individually so a failure on one column
	# (e.g. column already exists) does not prevent subsequent columns from
	# being checked.
	local usage_cols
	usage_cols="$(sqlite3 "$LOCAL_USAGE_DB" "PRAGMA table_info('model_usage');" 2>/dev/null || echo "")"
	if [[ -n "$usage_cols" ]]; then
		if ! printf '%s' "$usage_cols" | grep -q "session_id"; then
			sqlite3 "$LOCAL_USAGE_DB" "ALTER TABLE model_usage ADD COLUMN session_id TEXT DEFAULT '';" 2>/dev/null || true
		fi
	fi

	local inv_cols
	inv_cols="$(sqlite3 "$LOCAL_USAGE_DB" "PRAGMA table_info('model_inventory');" 2>/dev/null || echo "")"
	if [[ -n "$inv_cols" ]]; then
		if ! printf '%s' "$inv_cols" | grep -q "file_path"; then
			sqlite3 "$LOCAL_USAGE_DB" "ALTER TABLE model_inventory ADD COLUMN file_path TEXT NOT NULL DEFAULT '';" 2>/dev/null || true
		fi
		if ! printf '%s' "$inv_cols" | grep -q "repo_source"; then
			sqlite3 "$LOCAL_USAGE_DB" "ALTER TABLE model_inventory ADD COLUMN repo_source TEXT DEFAULT '';" 2>/dev/null || true
		fi
		if ! printf '%s' "$inv_cols" | grep -q "size_bytes"; then
			sqlite3 "$LOCAL_USAGE_DB" "ALTER TABLE model_inventory ADD COLUMN size_bytes INTEGER DEFAULT 0;" 2>/dev/null || true
		fi
		if ! printf '%s' "$inv_cols" | grep -q "quantization"; then
			sqlite3 "$LOCAL_USAGE_DB" "ALTER TABLE model_inventory ADD COLUMN quantization TEXT DEFAULT '';" 2>/dev/null || true
		fi
		if ! printf '%s' "$inv_cols" | grep -q "first_seen"; then
			sqlite3 "$LOCAL_USAGE_DB" "ALTER TABLE model_inventory ADD COLUMN first_seen TEXT NOT NULL DEFAULT '';" 2>/dev/null || true
			sqlite3 "$LOCAL_USAGE_DB" "UPDATE model_inventory SET first_seen = datetime('now') WHERE first_seen = '';" 2>/dev/null || true
		fi
	fi

	# Ensure indexes exist
	sqlite3 "$LOCAL_USAGE_DB" <<-'SQLEOF' 2>/dev/null || true
		CREATE INDEX IF NOT EXISTS idx_model_usage_model ON model_usage(model);
		CREATE INDEX IF NOT EXISTS idx_model_usage_timestamp ON model_usage(timestamp);
		CREATE INDEX IF NOT EXISTS idx_model_usage_session ON model_usage(session_id);
		CREATE INDEX IF NOT EXISTS idx_model_inventory_last_used ON model_inventory(last_used);
	SQLEOF
	return 0
}

# Record a usage event (t1338.5: per-session logging)
record_usage() {
	local model="$1"
	local tokens_in="${2:-0}"
	local tokens_out="${3:-0}"
	local duration_ms="${4:-0}"
	local tok_per_sec="${5:-0.0}"
	local session_id="${6:-${CLAUDE_SESSION_ID:-${OPENCODE_SESSION_ID:-}}}"

	if ! suppress_stderr command -v sqlite3 || [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		return 0
	fi

	local escaped_model escaped_session
	escaped_model="$(sql_escape "$model")"
	escaped_session="$(sql_escape "$session_id")"

	# Sanitize numeric parameters to prevent SQL injection via integer/real fields
	local safe_tokens_in safe_tokens_out safe_duration_ms safe_tok_per_sec
	safe_tokens_in="$(sql_int "$tokens_in")"
	safe_tokens_out="$(sql_int "$tokens_out")"
	safe_duration_ms="$(sql_int "$duration_ms")"
	safe_tok_per_sec="$(sql_real "$tok_per_sec")"

	log_stderr "record_usage" sqlite3 "$LOCAL_USAGE_DB" <<-SQLEOF
		INSERT INTO model_usage (model, session_id, tokens_in, tokens_out, duration_ms, tok_per_sec)
		VALUES ('${escaped_model}', '${escaped_session}', ${safe_tokens_in}, ${safe_tokens_out}, ${safe_duration_ms}, ${safe_tok_per_sec});

		INSERT INTO model_inventory (model, total_requests)
		VALUES ('${escaped_model}', 1)
		ON CONFLICT(model) DO UPDATE SET
			last_used = datetime('now'),
			total_requests = total_requests + 1;
	SQLEOF
	return 0
}

# Register a model in the inventory when downloaded (t1338.5)
register_model_inventory() {
	local model_name="$1"
	local file_path="${2:-}"
	local repo_source="${3:-}"
	local size_bytes="${4:-0}"
	local quantization="${5:-}"

	if ! suppress_stderr command -v sqlite3 || [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		return 0
	fi

	local escaped_name escaped_path escaped_repo escaped_quant safe_size_bytes
	escaped_name="$(sql_escape "$model_name")"
	escaped_path="$(sql_escape "$file_path")"
	escaped_repo="$(sql_escape "$repo_source")"
	escaped_quant="$(sql_escape "$quantization")"
	safe_size_bytes="$(sql_int "$size_bytes")"

	log_stderr "register_model_inventory" sqlite3 "$LOCAL_USAGE_DB" <<-SQLEOF
		INSERT INTO model_inventory (model, file_path, repo_source, size_bytes, quantization)
		VALUES ('${escaped_name}', '${escaped_path}', '${escaped_repo}', ${safe_size_bytes}, '${escaped_quant}')
		ON CONFLICT(model) DO UPDATE SET
			file_path = '${escaped_path}',
			repo_source = CASE WHEN '${escaped_repo}' != '' THEN '${escaped_repo}' ELSE repo_source END,
			size_bytes = CASE WHEN ${safe_size_bytes} > 0 THEN ${safe_size_bytes} ELSE size_bytes END,
			quantization = CASE WHEN '${escaped_quant}' != '' THEN '${escaped_quant}' ELSE quantization END;
	SQLEOF
	return 0
}

# Sync model_inventory with files on disk (t1338.5)
# Scans LOCAL_MODELS_STORE and ensures every .gguf file is registered
sync_model_inventory() {
	if ! suppress_stderr command -v sqlite3 || [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		return 0
	fi

	if [[ ! -d "$LOCAL_MODELS_STORE" ]]; then
		return 0
	fi

	local models
	models="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f 2>/dev/null)"
	[[ -z "$models" ]] && return 0

	while IFS= read -r model_path; do
		local name size_bytes quant
		name="$(basename "$model_path")"

		if [[ "$(uname -s)" == "Darwin" ]]; then
			size_bytes="$(stat -f%z "$model_path" 2>/dev/null || echo "0")"
		else
			size_bytes="$(stat -c%s "$model_path" 2>/dev/null || echo "0")"
		fi

		# Extract quantization from filename
		quant="$(echo "$name" | grep -oiE '(q[0-9]_[a-z0-9_]+|iq[0-9]_[a-z0-9]+|f16|f32|bf16)' | head -1 | tr '[:lower:]' '[:upper:]')"

		register_model_inventory "$name" "$model_path" "" "$size_bytes" "$quant"
	done <<<"$models"

	# Mark models in inventory that no longer exist on disk
	local db_models
	db_models="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT model FROM model_inventory;" 2>/dev/null || echo "")"
	if [[ -n "$db_models" ]]; then
		while IFS= read -r db_model; do
			local found=false
			while IFS= read -r model_path; do
				if [[ "$(basename "$model_path")" == "$db_model" ]]; then
					found=true
					break
				fi
			done <<<"$models"
			if [[ "$found" == "false" ]]; then
				# Model file removed from disk — update inventory (keep record for history)
				local escaped_db_model
				escaped_db_model="$(sql_escape "$db_model")"
				sqlite3 "$LOCAL_USAGE_DB" "UPDATE model_inventory SET file_path = '' WHERE model = '${escaped_db_model}' AND file_path != '';" 2>/dev/null || true
			fi
		done <<<"$db_models"
	fi

	return 0
}

# Get the release asset name pattern for the current platform
get_release_asset_pattern() {
	local platform="$1"
	# llama.cpp releases use .tar.gz for macOS/Linux (changed from .zip circa b8100+)
	case "$platform" in
	macos-arm64) echo "llama-.*-bin-macos-arm64\\.tar\\.gz" ;;
	macos-x64) echo "llama-.*-bin-macos-x64\\.tar\\.gz" ;;
	linux-x64) echo "llama-.*-bin-ubuntu-x64\\.tar\\.gz" ;;
	linux-vulkan) echo "llama-.*-bin-ubuntu-vulkan-x64\\.tar\\.gz" ;;
	linux-rocm) echo "llama-.*-bin-ubuntu-rocm-.*-x64\\.tar\\.gz" ;;
	*) return 1 ;;
	esac
	return 0
}

# =============================================================================
# Command: setup
# =============================================================================

cmd_setup() {
	local update_mode=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--update)
			update_mode=true
			shift
			;;
		*) shift ;;
		esac
	done

	ensure_dirs

	print_info "Detecting platform..."
	local platform
	platform="$(detect_platform)" || return 1
	print_info "Platform: ${platform}"

	local gpu
	gpu="$(detect_gpu)"
	print_info "GPU: ${gpu}"

	local mem_gb
	mem_gb="$(detect_available_memory_gb)"
	print_info "Total RAM: ${mem_gb} GB"

	# Check if llama-server already exists
	if [[ -f "$LLAMA_SERVER_BIN" ]] && [[ "$update_mode" == "false" ]]; then
		local current_version
		current_version="$("$LLAMA_SERVER_BIN" --version 2>/dev/null | head -1 || echo "unknown")"
		print_info "llama-server already installed: ${current_version}"
		print_info "Use 'local-model-helper.sh setup --update' to update"
	else
		# Download llama.cpp release
		print_info "Fetching latest llama.cpp release..."

		if ! suppress_stderr command -v curl; then
			print_error "curl is required but not found"
			return 2
		fi

		if ! suppress_stderr command -v tar && ! suppress_stderr command -v unzip; then
			print_error "tar or unzip is required but neither found"
			return 2
		fi

		local release_json
		release_json="$(curl -sL "$LLAMA_CPP_API")" || {
			print_error "Failed to fetch llama.cpp release info"
			return 1
		}

		local tag_name
		tag_name="$(echo "$release_json" | jq -r '.tag_name // empty')"
		if [[ -z "$tag_name" ]]; then
			print_error "Could not determine latest release tag (jq required)"
			return 1
		fi
		print_info "Latest release: ${tag_name}"

		local asset_pattern
		asset_pattern="$(get_release_asset_pattern "$platform")" || {
			print_error "No binary available for platform: ${platform}"
			return 1
		}

		local download_url
		download_url="$(echo "$release_json" | jq -r --arg pat "$asset_pattern" \
			'.assets[] | select(.name | test($pat)) | .browser_download_url' | head -1)"

		if [[ -z "$download_url" ]]; then
			print_error "No matching release asset for pattern: ${asset_pattern}"
			print_info "Available assets:"
			echo "$release_json" | jq -r '.assets[].name' 2>/dev/null | head -10
			return 1
		fi

		local asset_name
		asset_name="$(basename "$download_url")"
		print_info "Downloading ${asset_name}..."

		local tmp_dir
		tmp_dir="$(mktemp -d)"
		local tmp_archive="${tmp_dir}/${asset_name}"

		if ! curl -sL -o "$tmp_archive" "$download_url"; then
			print_error "Download failed: ${download_url}"
			rm -rf "$tmp_dir"
			return 1
		fi

		print_info "Extracting..."
		mkdir -p "$tmp_dir/extracted"
		if [[ "$asset_name" == *.tar.gz ]] || [[ "$asset_name" == *.tgz ]]; then
			if ! tar -xzf "$tmp_archive" -C "$tmp_dir/extracted"; then
				print_error "Extraction failed (tar.gz)"
				rm -rf "$tmp_dir"
				return 1
			fi
		elif [[ "$asset_name" == *.zip ]]; then
			if ! unzip -qo "$tmp_archive" -d "$tmp_dir/extracted"; then
				print_error "Extraction failed (zip)"
				rm -rf "$tmp_dir"
				return 1
			fi
		else
			print_error "Unknown archive format: ${asset_name}"
			rm -rf "$tmp_dir"
			return 1
		fi

		# Find and copy the server binary
		local server_bin
		server_bin="$(find "$tmp_dir/extracted" -name "llama-server" -type f | head -1)"
		if [[ -z "$server_bin" ]]; then
			# Some releases use different naming
			server_bin="$(find "$tmp_dir/extracted" -name "llama-server*" -type f ! -name "*.dll" | head -1)"
		fi

		if [[ -z "$server_bin" ]]; then
			print_error "llama-server binary not found in release archive"
			print_info "Archive contents:"
			find "$tmp_dir/extracted" -type f | head -20
			rm -rf "$tmp_dir"
			return 1
		fi

		cp "$server_bin" "$LLAMA_SERVER_BIN"
		chmod +x "$LLAMA_SERVER_BIN"

		# Also copy llama-cli if present (useful for benchmarking)
		local cli_bin
		cli_bin="$(find "$tmp_dir/extracted" -name "llama-cli" -type f | head -1)"
		if [[ -n "$cli_bin" ]]; then
			cp "$cli_bin" "$LLAMA_CLI_BIN"
			chmod +x "$LLAMA_CLI_BIN"
		fi

		rm -rf "$tmp_dir"

		local installed_version
		installed_version="$("$LLAMA_SERVER_BIN" --version 2>/dev/null | head -1 || echo "${tag_name}")"
		print_success "llama-server installed: ${installed_version}"
	fi

	# Install huggingface-cli if not present
	if ! suppress_stderr command -v huggingface-cli; then
		print_info "Installing huggingface-cli..."
		if suppress_stderr command -v pip3; then
			log_stderr "pip install" pip3 install --quiet "huggingface_hub[cli]" || {
				print_warning "Failed to install huggingface-cli via pip3"
				print_info "Install manually: pip3 install 'huggingface_hub[cli]'"
			}
		elif suppress_stderr command -v pip; then
			log_stderr "pip install" pip install --quiet "huggingface_hub[cli]" || {
				print_warning "Failed to install huggingface-cli via pip"
				print_info "Install manually: pip install 'huggingface_hub[cli]'"
			}
		else
			print_warning "pip not found — install huggingface-cli manually"
			print_info "Install: pip3 install 'huggingface_hub[cli]'"
		fi
	else
		print_info "huggingface-cli: already installed"
	fi

	# Write default config
	write_default_config

	# Initialize usage database
	init_usage_db

	print_success "Setup complete. Directory: ${LOCAL_MODELS_DIR}"
	print_info "Next: local-model-helper.sh recommend  (see model suggestions)"
	print_info "      local-model-helper.sh search \"qwen3 8b\"  (find models)"
	return 0
}

# =============================================================================
# Command: start
# =============================================================================

cmd_start() {
	local model=""
	local port="$LLAMA_PORT"
	local host="$LLAMA_HOST"
	local ctx_size="$LLAMA_CTX_SIZE"
	local gpu_layers="$LLAMA_GPU_LAYERS"
	local flash_attn="$LLAMA_FLASH_ATTN"
	local threads=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--model)
			model="$2"
			shift 2
			;;
		--port)
			port="$2"
			shift 2
			;;
		--host)
			host="$2"
			shift 2
			;;
		--ctx-size)
			ctx_size="$2"
			shift 2
			;;
		--gpu-layers)
			gpu_layers="$2"
			shift 2
			;;
		--threads)
			threads="$2"
			shift 2
			;;
		--no-flash-attn)
			flash_attn="false"
			shift
			;;
		*) shift ;;
		esac
	done

	# Verify llama-server is installed
	if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
		print_error "llama-server not found. Run: local-model-helper.sh setup"
		return 2
	fi

	# Check if already running
	if [[ -f "$LOCAL_PID_FILE" ]]; then
		local existing_pid
		existing_pid="$(cat "$LOCAL_PID_FILE")"
		if kill -0 "$existing_pid" 2>/dev/null; then
			print_error "Server already running (PID ${existing_pid}). Stop it first: local-model-helper.sh stop"
			return 4
		else
			# Stale PID file
			rm -f "$LOCAL_PID_FILE"
		fi
	fi

	# Resolve model path
	if [[ -z "$model" ]]; then
		# Try to find the most recently used model
		local latest_model
		latest_model="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')"
		if [[ -z "$latest_model" ]]; then
			# macOS find doesn't support -printf
			latest_model="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f 2>/dev/null | head -1)"
		fi
		if [[ -z "$latest_model" ]]; then
			print_error "No model specified and no models found in ${LOCAL_MODELS_STORE}"
			print_info "Download a model first: local-model-helper.sh download <repo> --quant Q4_K_M"
			return 3
		fi
		model="$latest_model"
		print_info "Using model: $(basename "$model")"
	fi

	# Resolve relative model name to full path
	if [[ ! -f "$model" ]]; then
		local resolved="${LOCAL_MODELS_STORE}/${model}"
		if [[ -f "$resolved" ]]; then
			model="$resolved"
		else
			print_error "Model not found: ${model}"
			print_info "Available models:"
			find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f -exec basename {} \; 2>/dev/null
			return 3
		fi
	fi

	# Auto-detect threads if not specified
	if [[ -z "$threads" ]]; then
		threads="$(detect_threads)"
	fi

	# Build server arguments
	local server_args=(
		"--model" "$model"
		"--port" "$port"
		"--host" "$host"
		"--ctx-size" "$ctx_size"
		"--n-gpu-layers" "$gpu_layers"
		"--threads" "$threads"
	)

	if [[ "$flash_attn" == "true" ]]; then
		server_args+=("--flash-attn")
	fi

	print_info "Starting llama-server..."
	print_info "  Model:      $(basename "$model")"
	print_info "  API:        http://${host}:${port}/v1"
	print_info "  Context:    ${ctx_size} tokens"
	print_info "  Threads:    ${threads}"
	print_info "  GPU layers: ${gpu_layers}"

	# Start server in background
	local log_file="${LOCAL_MODELS_DIR}/server.log"
	nohup "$LLAMA_SERVER_BIN" "${server_args[@]}" >"$log_file" 2>&1 &
	local server_pid=$!
	echo "$server_pid" >"$LOCAL_PID_FILE"

	# Wait briefly and verify it started
	sleep 2
	if ! kill -0 "$server_pid" 2>/dev/null; then
		print_error "Server failed to start. Check log: ${log_file}"
		rm -f "$LOCAL_PID_FILE"
		tail -20 "$log_file" 2>/dev/null
		return 1
	fi

	# Wait for health endpoint
	local retries=0
	local max_retries=15
	while [[ $retries -lt $max_retries ]]; do
		if curl -sf "http://${host}:${port}/health" >/dev/null 2>&1; then
			print_success "Server running (PID ${server_pid})"
			print_info "API endpoint: http://${host}:${port}/v1"
			print_info "Health check: curl http://${host}:${port}/health"
			return 0
		fi
		retries=$((retries + 1))
		sleep 1
	done

	print_warning "Server started (PID ${server_pid}) but health check not responding yet"
	print_info "It may still be loading the model. Check: curl http://${host}:${port}/health"
	return 0
}

# =============================================================================
# Command: stop
# =============================================================================

cmd_stop() {
	if [[ ! -f "$LOCAL_PID_FILE" ]]; then
		print_info "No server PID file found — server may not be running"
		# Try to find and kill any llama-server process
		local pids
		pids="$(pgrep -f "llama-server" 2>/dev/null || true)"
		if [[ -n "$pids" ]]; then
			print_info "Found llama-server process(es): ${pids}"
			echo "$pids" | while read -r pid; do
				kill "$pid" 2>/dev/null || true
			done
			print_success "Sent SIGTERM to llama-server process(es)"
		else
			print_info "No llama-server processes found"
		fi
		return 0
	fi

	local pid
	pid="$(cat "$LOCAL_PID_FILE")"
	if kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || true
		# Wait for graceful shutdown
		local retries=0
		while [[ $retries -lt 10 ]] && kill -0 "$pid" 2>/dev/null; do
			sleep 1
			retries=$((retries + 1))
		done
		if kill -0 "$pid" 2>/dev/null; then
			print_warning "Server did not stop gracefully, sending SIGKILL"
			kill -9 "$pid" 2>/dev/null || true
		fi
		print_success "Server stopped (PID ${pid})"
	else
		print_info "Server was not running (stale PID file)"
	fi

	rm -f "$LOCAL_PID_FILE"
	return 0
}

# =============================================================================
# Command: status
# =============================================================================

cmd_status() {
	local json_output=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		*) shift ;;
		esac
	done

	local running=false
	local pid=""
	local model_name=""
	local uptime_str=""
	local api_url=""

	# Check PID file
	if [[ -f "$LOCAL_PID_FILE" ]]; then
		pid="$(cat "$LOCAL_PID_FILE")"
		if kill -0 "$pid" 2>/dev/null; then
			running=true
		else
			rm -f "$LOCAL_PID_FILE"
		fi
	fi

	# If not found via PID file, check for any llama-server process
	if [[ "$running" == "false" ]]; then
		pid="$(pgrep -f "llama-server" 2>/dev/null | head -1 || true)"
		if [[ -n "$pid" ]]; then
			running=true
		fi
	fi

	# Load config for port info
	load_config
	api_url="http://${LLAMA_HOST}:${LLAMA_PORT}/v1"

	if [[ "$running" == "true" ]]; then
		# Try to get loaded model from /v1/models
		local models_response
		models_response="$(curl -sf "http://${LLAMA_HOST}:${LLAMA_PORT}/v1/models" 2>/dev/null || echo "")"
		if [[ -n "$models_response" ]] && suppress_stderr command -v jq; then
			model_name="$(echo "$models_response" | jq -r '.data[0].id // "unknown"' 2>/dev/null || echo "unknown")"
		fi

		# Calculate uptime from process start time
		if [[ "$(uname -s)" == "Darwin" ]]; then
			local start_time
			start_time="$(ps -p "$pid" -o lstart= 2>/dev/null || echo "")"
			if [[ -n "$start_time" ]]; then
				uptime_str="since ${start_time}"
			fi
		else
			local elapsed
			elapsed="$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d ' ' || echo "")"
			if [[ -n "$elapsed" ]]; then
				local hours=$((elapsed / 3600))
				local mins=$(((elapsed % 3600) / 60))
				uptime_str="${hours}h ${mins}m"
			fi
		fi
	fi

	if [[ "$json_output" == "true" ]]; then
		cat <<-JSONEOF
			{
			  "running": ${running},
			  "pid": "${pid}",
			  "model": "${model_name}",
			  "api_url": "${api_url}",
			  "uptime": "${uptime_str}"
			}
		JSONEOF
		return 0
	fi

	if [[ "$running" == "true" ]]; then
		echo -e "${GREEN}Server: running${NC} (PID ${pid})"
		[[ -n "$model_name" ]] && echo "Model:  ${model_name}"
		echo "API:    ${api_url}"
		[[ -n "$uptime_str" ]] && echo "Uptime: ${uptime_str}"
	else
		echo -e "${YELLOW}Server: not running${NC}"
		echo "Start:  local-model-helper.sh start --model <model.gguf>"
	fi

	# Show installed binary version
	if [[ -x "$LLAMA_SERVER_BIN" ]]; then
		local version
		version="$("$LLAMA_SERVER_BIN" --version 2>/dev/null | head -1 || echo "installed")"
		echo "Binary: ${version}"
	else
		echo "Binary: not installed (run: local-model-helper.sh setup)"
	fi

	# Show model count and disk usage
	local model_count
	model_count="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f 2>/dev/null | wc -l | tr -d ' ')"
	if [[ "$model_count" -gt 0 ]]; then
		local total_size
		if [[ "$(uname -s)" == "Darwin" ]]; then
			total_size="$(du -sh "$LOCAL_MODELS_STORE" 2>/dev/null | awk '{print $1}')"
		else
			total_size="$(du -sh "$LOCAL_MODELS_STORE" 2>/dev/null | awk '{print $1}')"
		fi
		echo "Models: ${model_count} downloaded (${total_size})"
	else
		echo "Models: none downloaded"
	fi

	return 0
}

# =============================================================================
# Command: models
# =============================================================================

cmd_models() {
	local json_output=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ ! -d "$LOCAL_MODELS_STORE" ]]; then
		print_info "No models directory. Run: local-model-helper.sh setup"
		return 0
	fi

	local models
	models="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f 2>/dev/null)"

	if [[ -z "$models" ]]; then
		print_info "No models downloaded yet"
		print_info "Search: local-model-helper.sh search \"qwen3 8b\""
		print_info "Download: local-model-helper.sh download <repo> --quant Q4_K_M"
		return 0
	fi

	if [[ "$json_output" == "true" ]]; then
		echo "["
		local first=true
		while IFS= read -r model_path; do
			local name size_bytes last_used
			name="$(basename "$model_path")"
			if [[ "$(uname -s)" == "Darwin" ]]; then
				size_bytes="$(stat -f%z "$model_path" 2>/dev/null || echo "0")"
			else
				size_bytes="$(stat -c%s "$model_path" 2>/dev/null || echo "0")"
			fi
			last_used=""
			if suppress_stderr command -v sqlite3 && [[ -f "$LOCAL_USAGE_DB" ]]; then
				local escaped_name_json
				escaped_name_json="$(sql_escape "$name")"
				last_used="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT last_used FROM model_inventory WHERE model='${escaped_name_json}' LIMIT 1;" 2>/dev/null || echo "")"
			fi
			[[ "$first" == "true" ]] || echo ","
			first=false
			printf '  {"name": "%s", "size_bytes": %s, "last_used": "%s"}' "$name" "$size_bytes" "$last_used"
		done <<<"$models"
		echo ""
		echo "]"
		return 0
	fi

	# Table header
	printf "%-40s %10s %8s %12s\n" "NAME" "SIZE" "QUANT" "LAST USED"
	printf "%-40s %10s %8s %12s\n" "----" "----" "-----" "---------"

	while IFS= read -r model_path; do
		local name size_human quant last_used_str
		name="$(basename "$model_path")"

		# Get human-readable size
		if [[ "$(uname -s)" == "Darwin" ]]; then
			local size_bytes
			size_bytes="$(stat -f%z "$model_path" 2>/dev/null || echo "0")"
			size_human="$(echo "$size_bytes" | awk '{
				if ($1 >= 1073741824) printf "%.1f GB", $1/1073741824;
				else if ($1 >= 1048576) printf "%.0f MB", $1/1048576;
				else printf "%.0f KB", $1/1024;
			}')"
		else
			size_human="$(du -h "$model_path" 2>/dev/null | awk '{print $1}')"
		fi

		# Extract quantization from filename
		quant="$(echo "$name" | grep -oiE '(q[0-9]_[a-z0-9_]+|iq[0-9]_[a-z0-9]+|f16|f32|bf16)' | head -1 | tr '[:lower:]' '[:upper:]')"
		[[ -z "$quant" ]] && quant="-"

		# Get last used from database
		last_used_str="-"
		if suppress_stderr command -v sqlite3 && [[ -f "$LOCAL_USAGE_DB" ]]; then
			local db_last escaped_name_tbl
			escaped_name_tbl="$(sql_escape "$name")"
			db_last="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT last_used FROM model_inventory WHERE model='${escaped_name_tbl}' LIMIT 1;" 2>/dev/null || echo "")"
			if [[ -n "$db_last" ]]; then
				# Show relative time
				local now_epoch last_epoch diff_days
				now_epoch="$(date +%s)"
				last_epoch="$(date -j -f "%Y-%m-%d %H:%M:%S" "$db_last" +%s 2>/dev/null || date -d "$db_last" +%s 2>/dev/null || echo "0")"
				if [[ "$last_epoch" -gt 0 ]]; then
					diff_days="$(((now_epoch - last_epoch) / 86400))"
					if [[ "$diff_days" -eq 0 ]]; then
						last_used_str="today"
					elif [[ "$diff_days" -eq 1 ]]; then
						last_used_str="1d ago"
					else
						last_used_str="${diff_days}d ago"
					fi
				fi
			fi
		fi

		printf "%-40s %10s %8s %12s\n" "$name" "$size_human" "$quant" "$last_used_str"
	done <<<"$models"

	return 0
}

# =============================================================================
# Command: download
# =============================================================================

cmd_download() {
	local repo=""
	local quant="Q4_K_M"
	local filename=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--quant)
			quant="$2"
			shift 2
			;;
		--file)
			filename="$2"
			shift 2
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$repo" ]]; then
				repo="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$repo" ]]; then
		print_error "Repository is required"
		print_info "Usage: local-model-helper.sh download <owner/repo> [--quant Q4_K_M]"
		print_info "Example: local-model-helper.sh download Qwen/Qwen3-8B-GGUF --quant Q4_K_M"
		return 1
	fi

	ensure_dirs

	# Check for huggingface-cli
	if ! suppress_stderr command -v huggingface-cli; then
		print_error "huggingface-cli not found. Run: local-model-helper.sh setup"
		return 2
	fi

	# If no specific filename, find matching GGUF file in the repo
	if [[ -z "$filename" ]]; then
		print_info "Searching for ${quant} quantization in ${repo}..."

		local quant_lower
		quant_lower="$(echo "$quant" | tr '[:upper:]' '[:lower:]')"

		# List files in the repo via HuggingFace API
		local files_json
		files_json="$(curl -sL "${HF_API}/models/${repo}" 2>/dev/null || echo "")"

		if [[ -z "$files_json" ]]; then
			print_error "Could not fetch repo info for: ${repo}"
			return 1
		fi

		# Try to find a matching GGUF file from siblings
		local siblings_json
		siblings_json="$(echo "$files_json" | jq -r '.siblings[]?.rfilename // empty' 2>/dev/null || echo "")"

		if [[ -n "$siblings_json" ]]; then
			filename="$(echo "$siblings_json" | grep -i "\.gguf$" | grep -i "$quant_lower" | head -1)"
		fi

		# If not found in siblings, try the tree API
		if [[ -z "$filename" ]]; then
			local tree_json
			tree_json="$(curl -sL "${HF_API}/models/${repo}/tree/main" 2>/dev/null || echo "")"
			if [[ -n "$tree_json" ]]; then
				filename="$(echo "$tree_json" | jq -r '.[].path // empty' 2>/dev/null | grep -i "\.gguf$" | grep -i "$quant_lower" | head -1)"
			fi
		fi

		if [[ -z "$filename" ]]; then
			print_error "No GGUF file matching quantization '${quant}' found in ${repo}"
			print_info "Available GGUF files:"
			if [[ -n "$siblings_json" ]]; then
				echo "$siblings_json" | grep -i "\.gguf$" | head -10
			fi
			print_info "Specify exact file: --file <filename.gguf>"
			return 3
		fi

		print_info "Found: ${filename}"
	fi

	print_info "Downloading ${filename} from ${repo}..."
	print_info "Destination: ${LOCAL_MODELS_STORE}/"

	# Use huggingface-cli for download (supports resume)
	if ! huggingface-cli download "$repo" "$filename" \
		--local-dir "$LOCAL_MODELS_STORE" \
		--local-dir-use-symlinks False 2>&1; then
		print_error "Download failed"
		return 1
	fi

	# Verify the file exists
	local downloaded_path="${LOCAL_MODELS_STORE}/${filename}"
	if [[ -f "$downloaded_path" ]]; then
		local size_human size_bytes_dl
		if [[ "$(uname -s)" == "Darwin" ]]; then
			size_bytes_dl="$(stat -f%z "$downloaded_path" 2>/dev/null || echo "0")"
		else
			size_bytes_dl="$(stat -c%s "$downloaded_path" 2>/dev/null || echo "0")"
		fi
		size_human="$(echo "$size_bytes_dl" | awk '{
			if ($1 >= 1073741824) printf "%.1f GB", $1/1073741824;
			else printf "%.0f MB", $1/1048576;
		}')"
		print_success "Downloaded: ${filename} (${size_human})"

		# Register in model inventory (t1338.5)
		local dl_quant
		dl_quant="$(echo "$filename" | grep -oiE '(q[0-9]_[a-z0-9_]+|iq[0-9]_[a-z0-9]+|f16|f32|bf16)' | head -1 | tr '[:lower:]' '[:upper:]')"
		register_model_inventory "$filename" "$downloaded_path" "$repo" "$size_bytes_dl" "$dl_quant"
	else
		print_success "Download complete (file may be in a subdirectory)"
	fi

	return 0
}

# =============================================================================
# Command: search
# =============================================================================

cmd_search() {
	local query=""
	local limit=10

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--limit)
			limit="$2"
			shift 2
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$query" ]]; then
				query="$1"
			else
				query="${query} $1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$query" ]]; then
		print_error "Search query is required"
		print_info "Usage: local-model-helper.sh search \"qwen3 8b\""
		return 1
	fi

	print_info "Searching HuggingFace for GGUF models: ${query}..."

	# URL-encode the query
	local encoded_query
	encoded_query="$(printf '%s' "$query" | sed 's/ /+/g')"

	local search_url="${HF_API}/models?search=${encoded_query}+gguf&filter=gguf&sort=downloads&direction=-1&limit=${limit}"
	local results
	results="$(curl -sL "$search_url" 2>/dev/null || echo "")"

	if [[ -z "$results" ]] || [[ "$results" == "[]" ]]; then
		print_info "No results found for: ${query}"
		print_info "Try broader terms or check HuggingFace directly"
		return 0
	fi

	if ! suppress_stderr command -v jq; then
		print_error "jq is required for search results parsing"
		echo "$results"
		return 0
	fi

	# Parse and display results
	printf "%-50s %12s %10s\n" "REPOSITORY" "DOWNLOADS" "UPDATED"
	printf "%-50s %12s %10s\n" "----------" "---------" "-------"

	echo "$results" | jq -r '.[] | [.modelId, (.downloads // 0 | tostring), (.lastModified // "-" | split("T")[0])] | @tsv' 2>/dev/null |
		while IFS=$'\t' read -r model_id downloads updated; do
			printf "%-50s %12s %10s\n" "$model_id" "$downloads" "$updated"
		done

	echo ""
	print_info "Download: local-model-helper.sh download <repo> --quant Q4_K_M"
	return 0
}

# =============================================================================
# Command: recommend
# =============================================================================

cmd_recommend() {
	local json_output=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		*) shift ;;
		esac
	done

	local mem_gb gpu platform threads
	mem_gb="$(detect_available_memory_gb)"
	gpu="$(detect_gpu)"
	platform="$(detect_platform 2>/dev/null || echo "unknown")"
	threads="$(detect_threads)"

	# Calculate usable memory for models (reserve 4 GB for OS)
	local usable_gb=0
	if [[ "$mem_gb" -gt 4 ]]; then
		usable_gb=$((mem_gb - 4))
	fi

	if [[ "$json_output" == "true" ]]; then
		cat <<-JSONEOF
			{
			  "platform": "${platform}",
			  "total_ram_gb": ${mem_gb},
			  "usable_for_models_gb": ${usable_gb},
			  "gpu": "${gpu}",
			  "threads": ${threads}
			}
		JSONEOF
		return 0
	fi

	echo "Hardware Detection"
	echo "=================="
	echo "Platform:  ${platform}"
	echo "Total RAM: ${mem_gb} GB"
	echo "Usable:    ${usable_gb} GB (reserving 4 GB for OS)"
	echo "GPU:       ${gpu}"
	echo "Threads:   ${threads} (performance cores)"
	echo ""

	echo "Recommended Models"
	echo "=================="

	if [[ "$usable_gb" -lt 4 ]]; then
		echo "  Your system has limited memory for local models."
		echo "  Consider cloud tiers (haiku, flash) instead."
		echo ""
		echo "  Smallest option: Phi-4-mini Q4_K_M (~1.5 GB)"
		echo "    local-model-helper.sh download microsoft/Phi-4-mini-instruct-GGUF --quant Q4_K_M"
	elif [[ "$usable_gb" -lt 8 ]]; then
		echo "  Small  (fast):     Qwen3-4B Q4_K_M     (~2.5 GB, ~40 tok/s)"
		echo "  Medium (balanced): Phi-4 Q4_K_M         (~4 GB, ~30 tok/s)"
		echo ""
		echo "  Your hardware can run models up to ~4 GB comfortably."
	elif [[ "$usable_gb" -lt 16 ]]; then
		echo "  Small  (fast):     Qwen3-4B Q4_K_M     (~2.5 GB, ~40 tok/s)"
		echo "  Medium (balanced): Qwen3-8B Q4_K_M     (~5 GB, ~25 tok/s)"
		echo "  Large  (capable):  Llama-3.1-8B Q6_K   (~6.5 GB, ~18 tok/s)"
		echo ""
		echo "  Your hardware can run models up to ~10 GB comfortably."
	elif [[ "$usable_gb" -lt 32 ]]; then
		echo "  Small  (fast):     Qwen3-8B Q4_K_M     (~5 GB, ~25 tok/s)"
		echo "  Medium (balanced): Qwen3-14B Q4_K_M    (~8 GB, ~15 tok/s)"
		echo "  Large  (capable):  DeepSeek-R1-14B Q6_K (~11 GB, ~10 tok/s)"
		echo ""
		echo "  Your hardware can run models up to ~20 GB comfortably."
	elif [[ "$usable_gb" -lt 64 ]]; then
		echo "  Small  (fast):     Qwen3-14B Q4_K_M    (~8 GB, ~15 tok/s)"
		echo "  Medium (balanced): Qwen3-32B Q4_K_M    (~18 GB, ~8 tok/s)"
		echo "  Large  (capable):  Llama-3.1-70B Q4_K_M (~40 GB, ~4 tok/s)"
		echo ""
		echo "  Your hardware can run models up to ~45 GB comfortably."
	else
		echo "  Small  (fast):     Qwen3-32B Q4_K_M    (~18 GB, ~8 tok/s)"
		echo "  Medium (balanced): Llama-3.1-70B Q4_K_M (~40 GB, ~4 tok/s)"
		echo "  Large  (capable):  Llama-3.1-70B Q6_K  (~55 GB, ~3 tok/s)"
		echo ""
		echo "  Your hardware can run models up to ~${usable_gb} GB."
	fi

	echo ""
	echo "Quantization Guide"
	echo "=================="
	echo "  Q4_K_M  — Best size/quality balance (default)"
	echo "  Q5_K_M  — Better quality, ~33% larger"
	echo "  Q6_K    — Near-lossless, ~50% of FP16 size"
	echo "  Q8_0    — Maximum quality, ~66% of FP16 size"
	echo "  IQ4_XS  — Smallest usable, slight quality loss"
	echo ""
	echo "Next steps:"
	echo "  local-model-helper.sh search \"qwen3 8b gguf\""
	echo "  local-model-helper.sh download <repo> --quant Q4_K_M"

	return 0
}

# =============================================================================
# Command: cleanup
# =============================================================================

cmd_cleanup() {
	local remove_stale=false
	local remove_model=""
	local threshold="$STALE_THRESHOLD_DAYS"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--remove-stale)
			remove_stale=true
			shift
			;;
		--remove)
			remove_model="$2"
			shift 2
			;;
		--threshold)
			threshold="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Validate threshold is a non-negative integer
	if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
		print_error "Invalid --threshold value '${threshold}'. Must be a non-negative integer (days)."
		return 1
	fi

	if [[ ! -d "$LOCAL_MODELS_STORE" ]]; then
		print_info "No models directory found"
		return 0
	fi

	local models
	models="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f 2>/dev/null)"

	if [[ -z "$models" ]]; then
		print_info "No models to clean up"
		return 0
	fi

	# Handle specific model removal
	if [[ -n "$remove_model" ]]; then
		local target="${LOCAL_MODELS_STORE}/${remove_model}"
		if [[ -f "$target" ]]; then
			local size_human
			if [[ "$(uname -s)" == "Darwin" ]]; then
				local size_bytes
				size_bytes="$(stat -f%z "$target" 2>/dev/null || echo "0")"
				size_human="$(echo "$size_bytes" | awk '{printf "%.1f GB", $1/1073741824}')"
			else
				size_human="$(du -h "$target" | awk '{print $1}')"
			fi
			rm -f "$target"
			print_success "Removed: ${remove_model} (${size_human})"
			# Clean up database entry
			if suppress_stderr command -v sqlite3 && [[ -f "$LOCAL_USAGE_DB" ]]; then
				local escaped_rm
				escaped_rm="$(sql_escape "$remove_model")"
				sqlite3 "$LOCAL_USAGE_DB" "DELETE FROM model_inventory WHERE model='${escaped_rm}';" 2>/dev/null || true
			fi
		else
			print_error "Model not found: ${remove_model}"
			return 3
		fi
		return 0
	fi

	# Show cleanup report
	local now_epoch total_size_bytes stale_size_bytes stale_count
	now_epoch="$(date +%s)"
	total_size_bytes=0
	stale_size_bytes=0
	stale_count=0

	printf "%-40s %10s %12s %10s\n" "MODEL" "SIZE" "LAST USED" "STATUS"
	printf "%-40s %10s %12s %10s\n" "-----" "----" "---------" "------"

	while IFS= read -r model_path; do
		local name size_bytes size_human last_used_str status_str days_unused
		name="$(basename "$model_path")"

		if [[ "$(uname -s)" == "Darwin" ]]; then
			size_bytes="$(stat -f%z "$model_path" 2>/dev/null || echo "0")"
		else
			size_bytes="$(stat -c%s "$model_path" 2>/dev/null || echo "0")"
		fi
		total_size_bytes=$((total_size_bytes + size_bytes))

		size_human="$(echo "$size_bytes" | awk '{
			if ($1 >= 1073741824) printf "%.1f GB", $1/1073741824;
			else printf "%.0f MB", $1/1048576;
		}')"

		# Check last used
		days_unused="-"
		last_used_str="-"
		status_str="unknown"

		if suppress_stderr command -v sqlite3 && [[ -f "$LOCAL_USAGE_DB" ]]; then
			local db_last escaped_name_cl
			escaped_name_cl="$(sql_escape "$name")"
			db_last="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT last_used FROM model_inventory WHERE model='${escaped_name_cl}' LIMIT 1;" 2>/dev/null || echo "")"
			if [[ -n "$db_last" ]]; then
				local last_epoch
				last_epoch="$(date -j -f "%Y-%m-%d %H:%M:%S" "$db_last" +%s 2>/dev/null || date -d "$db_last" +%s 2>/dev/null || echo "0")"
				if [[ "$last_epoch" -gt 0 ]]; then
					days_unused="$(((now_epoch - last_epoch) / 86400))"
					if [[ "$days_unused" -eq 0 ]]; then
						last_used_str="today"
					elif [[ "$days_unused" -eq 1 ]]; then
						last_used_str="1d ago"
					else
						last_used_str="${days_unused}d ago"
					fi
				fi
			fi
		fi

		# Fall back to file modification time if no DB entry
		if [[ "$last_used_str" == "-" ]]; then
			if [[ "$(uname -s)" == "Darwin" ]]; then
				local mod_epoch
				mod_epoch="$(stat -f%m "$model_path" 2>/dev/null || echo "0")"
				if [[ "$mod_epoch" -gt 0 ]]; then
					days_unused="$(((now_epoch - mod_epoch) / 86400))"
					last_used_str="${days_unused}d ago (mtime)"
				fi
			else
				local mod_epoch
				mod_epoch="$(stat -c%Y "$model_path" 2>/dev/null || echo "0")"
				if [[ "$mod_epoch" -gt 0 ]]; then
					days_unused="$(((now_epoch - mod_epoch) / 86400))"
					last_used_str="${days_unused}d ago (mtime)"
				fi
			fi
		fi

		if [[ "$days_unused" != "-" ]] && [[ "$days_unused" -gt "$threshold" ]]; then
			status_str="stale (>${threshold}d)"
			stale_size_bytes=$((stale_size_bytes + size_bytes))
			stale_count=$((stale_count + 1))
		else
			status_str="active"
		fi

		printf "%-40s %10s %12s %10s\n" "$name" "$size_human" "$last_used_str" "$status_str"
	done <<<"$models"

	echo ""
	local total_human stale_human
	total_human="$(echo "$total_size_bytes" | awk '{printf "%.1f GB", $1/1073741824}')"
	stale_human="$(echo "$stale_size_bytes" | awk '{printf "%.1f GB", $1/1073741824}')"
	echo "Total: ${total_human} (${stale_human} stale)"

	if [[ "$stale_count" -gt 0 ]]; then
		echo "Recommendation: Remove ${stale_count} stale model(s) to free ${stale_human}"
		echo ""
		if [[ "$remove_stale" == "true" ]]; then
			print_info "Removing stale models..."
			while IFS= read -r model_path; do
				local name days_unused_check
				name="$(basename "$model_path")"
				days_unused_check=-1

				if suppress_stderr command -v sqlite3 && [[ -f "$LOCAL_USAGE_DB" ]]; then
					local db_last escaped_name_rm
					escaped_name_rm="$(sql_escape "$name")"
					db_last="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT last_used FROM model_inventory WHERE model='${escaped_name_rm}' LIMIT 1;" 2>/dev/null || echo "")"
					if [[ -n "$db_last" ]]; then
						local last_epoch
						last_epoch="$(date -j -f "%Y-%m-%d %H:%M:%S" "$db_last" +%s 2>/dev/null || date -d "$db_last" +%s 2>/dev/null || echo "0")"
						if [[ "$last_epoch" -gt 0 ]]; then
							days_unused_check="$(((now_epoch - last_epoch) / 86400))"
						fi
					fi
				fi

				# Fall back to mtime only when DB lookup returned no result
				if [[ "$days_unused_check" -lt 0 ]]; then
					if [[ "$(uname -s)" == "Darwin" ]]; then
						local mod_epoch
						mod_epoch="$(stat -f%m "$model_path" 2>/dev/null || echo "0")"
						if [[ "$mod_epoch" -gt 0 ]]; then
							days_unused_check="$(((now_epoch - mod_epoch) / 86400))"
						fi
					else
						local mod_epoch
						mod_epoch="$(stat -c%Y "$model_path" 2>/dev/null || echo "0")"
						if [[ "$mod_epoch" -gt 0 ]]; then
							days_unused_check="$(((now_epoch - mod_epoch) / 86400))"
						fi
					fi
				fi

				if [[ "$days_unused_check" -gt "$threshold" ]]; then
					rm -f "$model_path"
					print_success "Removed: ${name}"
					if suppress_stderr command -v sqlite3 && [[ -f "$LOCAL_USAGE_DB" ]]; then
						sqlite3 "$LOCAL_USAGE_DB" "DELETE FROM model_inventory WHERE model='$(sql_escape "$name")';" 2>/dev/null || true
					fi
				fi
			done <<<"$models"
		else
			echo "Run: local-model-helper.sh cleanup --remove-stale"
		fi
	fi

	return 0
}

# =============================================================================
# Command: usage
# =============================================================================

cmd_usage() {
	local json_output=false
	local since=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		--since)
			since="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if ! suppress_stderr command -v sqlite3; then
		print_error "sqlite3 is required for usage tracking"
		return 2
	fi

	if [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		print_info "No usage data yet. Start using local models to track usage."
		return 0
	fi

	local where_clause=""
	if [[ -n "$since" ]]; then
		# Validate date format (YYYY-MM-DD with optional time) to prevent SQL injection
		if ! [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([[:space:]][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$ ]]; then
			print_error "Invalid --since format. Use YYYY-MM-DD or 'YYYY-MM-DD HH:MM:SS'"
			return 1
		fi
		local escaped_since
		escaped_since="$(sql_escape "$since")"
		where_clause="WHERE u.timestamp >= '${escaped_since}'"
	fi

	if [[ "$json_output" == "true" ]]; then
		local json_sql
		json_sql="SELECT model, COUNT(*) as requests, SUM(tokens_in) as total_tokens_in, SUM(tokens_out) as total_tokens_out, ROUND(AVG(tok_per_sec), 1) as avg_tok_per_sec, MAX(timestamp) as last_used FROM model_usage u ${where_clause} GROUP BY model ORDER BY last_used DESC;"
		sqlite3 -json "$LOCAL_USAGE_DB" "$json_sql" 2>/dev/null
		return 0
	fi

	# Table output
	printf "%-35s %8s %10s %10s %10s %12s\n" "MODEL" "REQUESTS" "TOKENS_IN" "TOKENS_OUT" "AVG_TOK/S" "LAST_USED"
	printf "%-35s %8s %10s %10s %10s %12s\n" "-----" "--------" "---------" "----------" "---------" "---------"

	local usage_sql
	usage_sql="SELECT model, COUNT(*) as requests, SUM(tokens_in) as total_tokens_in, SUM(tokens_out) as total_tokens_out, ROUND(AVG(tok_per_sec), 1) as avg_tok_per_sec, MAX(timestamp) as last_used FROM model_usage u ${where_clause} GROUP BY model ORDER BY last_used DESC;"

	sqlite3 -separator $'\t' "$LOCAL_USAGE_DB" "$usage_sql" 2>/dev/null |
		while IFS=$'\t' read -r model requests tokens_in tokens_out avg_tps last_used; do
			# Truncate model name if too long
			local display_model="$model"
			if [[ ${#display_model} -gt 35 ]]; then
				display_model="${display_model:0:32}..."
			fi
			printf "%-35s %8s %10s %10s %10s %12s\n" \
				"$display_model" "$requests" "$tokens_in" "$tokens_out" "$avg_tps" "${last_used%% *}"
		done

	echo ""

	# Summary
	local summary_sql summary
	summary_sql="SELECT COUNT(*) as total_requests, COALESCE(SUM(tokens_in), 0) as total_in, COALESCE(SUM(tokens_out), 0) as total_out FROM model_usage u ${where_clause};"
	summary="$(sqlite3 -separator $'\t' "$LOCAL_USAGE_DB" "$summary_sql" 2>/dev/null)"

	if [[ -n "$summary" ]]; then
		local total_req total_in total_out
		IFS=$'\t' read -r total_req total_in total_out <<<"$summary"
		echo "Total: ${total_req} requests, ${total_in} input tokens, ${total_out} output tokens"

		# Estimate cloud cost savings (haiku: $0.25/MTok in, $1.25/MTok out; sonnet: $3/MTok in, $15/MTok out)
		if [[ "$total_in" -gt 0 ]] || [[ "$total_out" -gt 0 ]]; then
			local haiku_cost sonnet_cost
			haiku_cost="$(echo "$total_in $total_out" | awk '{printf "%.2f", ($1 * 0.00000025 + $2 * 0.00000125)}')"
			sonnet_cost="$(echo "$total_in $total_out" | awk '{printf "%.2f", ($1 * 0.000003 + $2 * 0.000015)}')"
			echo "Estimated cloud cost saved: \$${haiku_cost} (vs haiku), \$${sonnet_cost} (vs sonnet)"
		fi
	fi

	return 0
}

# =============================================================================
# Command: benchmark
# =============================================================================

cmd_benchmark() {
	local model=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--model)
			model="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$model" ]]; then
		print_error "Model is required for benchmarking"
		print_info "Usage: local-model-helper.sh benchmark --model <model.gguf>"
		return 1
	fi

	# Resolve model path
	if [[ ! -f "$model" ]]; then
		local resolved="${LOCAL_MODELS_STORE}/${model}"
		if [[ -f "$resolved" ]]; then
			model="$resolved"
		else
			print_error "Model not found: ${model}"
			return 3
		fi
	fi

	# Prefer llama-cli for benchmarking (more detailed output)
	local bench_bin="$LLAMA_SERVER_BIN"
	if [[ -x "$LLAMA_CLI_BIN" ]]; then
		bench_bin="$LLAMA_CLI_BIN"
	fi

	if [[ ! -x "$bench_bin" ]]; then
		print_error "llama.cpp not installed. Run: local-model-helper.sh setup"
		return 2
	fi

	local gpu threads
	gpu="$(detect_gpu)"
	threads="$(detect_threads)"

	echo "Benchmark"
	echo "========="
	echo "Model:    $(basename "$model")"
	echo "Hardware: ${gpu}"
	echo "Threads:  ${threads}"
	echo ""

	print_info "Running benchmark (this may take 30-60 seconds)..."

	# Use llama-cli with a standard prompt for benchmarking
	local bench_prompt="Explain the concept of recursion in computer science in exactly three paragraphs."

	if [[ "$bench_bin" == "$LLAMA_CLI_BIN" ]]; then
		local output
		output="$("$LLAMA_CLI_BIN" \
			--model "$model" \
			--threads "$threads" \
			--n-gpu-layers "$LLAMA_GPU_LAYERS" \
			--ctx-size "$LLAMA_CTX_SIZE" \
			--prompt "$bench_prompt" \
			--n-predict 256 \
			--log-disable \
			2>&1)" || true

		# Parse llama.cpp timing output
		local prompt_eval_rate gen_rate
		prompt_eval_rate="$(echo "$output" | grep -oP 'prompt eval time.*?(\d+\.\d+) tokens per second' | grep -oP '\d+\.\d+' | tail -1 || echo "-")"
		gen_rate="$(echo "$output" | grep -oP 'eval time.*?(\d+\.\d+) tokens per second' | grep -oP '\d+\.\d+' | tail -1 || echo "-")"

		# macOS grep doesn't support -P, try alternative
		if [[ "$prompt_eval_rate" == "-" ]]; then
			prompt_eval_rate="$(echo "$output" | grep "prompt eval time" | sed 's/.*(\([0-9.]*\) tokens per second).*/\1/' || echo "-")"
		fi
		if [[ "$gen_rate" == "-" ]]; then
			gen_rate="$(echo "$output" | grep "eval time" | grep -v "prompt" | sed 's/.*(\([0-9.]*\) tokens per second).*/\1/' || echo "-")"
		fi

		echo "Results:"
		echo "  Prompt eval: ${prompt_eval_rate} tok/s"
		echo "  Generation:  ${gen_rate} tok/s"
		echo "  Context:     ${LLAMA_CTX_SIZE} tokens"
	else
		# Fallback: use the server briefly
		print_info "Using llama-server for benchmark (llama-cli not available)"
		print_info "Start the server and use curl to measure response times"
		echo ""
		echo "Quick benchmark command:"
		echo "  time curl -s http://localhost:${LLAMA_PORT}/v1/chat/completions \\"
		echo "    -H 'Content-Type: application/json' \\"
		echo "    -d '{\"model\":\"local\",\"messages\":[{\"role\":\"user\",\"content\":\"${bench_prompt}\"}],\"max_tokens\":256}'"
	fi

	return 0
}

# =============================================================================
# Command: nudge (t1338.5 — session-start stale model notification)
# =============================================================================
# Called at session start to check if stale models exceed 5 GB.
# Outputs a short message if cleanup is recommended, nothing otherwise.
# Designed to be called from aidevops-update-check.sh or session init.

cmd_nudge() {
	local json_output=false
	local threshold="${STALE_THRESHOLD_DAYS}"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		--threshold)
			threshold="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Validate threshold is a non-negative integer
	if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
		print_error "Invalid --threshold value '${threshold}'. Must be a non-negative integer (days)."
		return 1
	fi

	# Quick exit if no models directory or no sqlite3
	if [[ ! -d "$LOCAL_MODELS_STORE" ]]; then
		return 0
	fi

	local models
	models="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f 2>/dev/null)"
	[[ -z "$models" ]] && return 0

	local now_epoch stale_size_bytes stale_count
	now_epoch="$(date +%s)"
	stale_size_bytes=0
	stale_count=0

	while IFS= read -r model_path; do
		local name size_bytes days_unused
		name="$(basename "$model_path")"
		days_unused=-1

		if [[ "$(uname -s)" == "Darwin" ]]; then
			size_bytes="$(stat -f%z "$model_path" 2>/dev/null || echo "0")"
		else
			size_bytes="$(stat -c%s "$model_path" 2>/dev/null || echo "0")"
		fi

		# Check last used from DB
		if suppress_stderr command -v sqlite3 && [[ -f "$LOCAL_USAGE_DB" ]]; then
			local db_last escaped_name_nudge
			escaped_name_nudge="$(sql_escape "$name")"
			db_last="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT last_used FROM model_inventory WHERE model='${escaped_name_nudge}' LIMIT 1;" 2>/dev/null || echo "")"
			if [[ -n "$db_last" ]]; then
				local last_epoch
				last_epoch="$(date -j -f "%Y-%m-%d %H:%M:%S" "$db_last" +%s 2>/dev/null || date -d "$db_last" +%s 2>/dev/null || echo "0")"
				if [[ "$last_epoch" -gt 0 ]]; then
					days_unused="$(((now_epoch - last_epoch) / 86400))"
				fi
			fi
		fi

		# Fall back to file modification time if DB lookup failed or returned no result
		if [[ "$days_unused" -lt 0 ]]; then
			if [[ "$(uname -s)" == "Darwin" ]]; then
				local mod_epoch
				mod_epoch="$(stat -f%m "$model_path" 2>/dev/null || echo "0")"
				if [[ "$mod_epoch" -gt 0 ]]; then
					days_unused="$(((now_epoch - mod_epoch) / 86400))"
				fi
			else
				local mod_epoch
				mod_epoch="$(stat -c%Y "$model_path" 2>/dev/null || echo "0")"
				if [[ "$mod_epoch" -gt 0 ]]; then
					days_unused="$(((now_epoch - mod_epoch) / 86400))"
				fi
			fi
		fi

		if [[ "$days_unused" -gt "$threshold" ]]; then
			stale_size_bytes=$((stale_size_bytes + size_bytes))
			stale_count=$((stale_count + 1))
		fi
	done <<<"$models"

	# Only nudge if stale models exceed threshold (default 5 GB)
	if [[ "$stale_size_bytes" -gt "$STALE_NUDGE_THRESHOLD_BYTES" ]]; then
		local stale_human
		stale_human="$(echo "$stale_size_bytes" | awk '{printf "%.1f GB", $1/1073741824}')"

		if [[ "$json_output" == "true" ]]; then
			cat <<-JSONEOF
				{
				  "stale_count": ${stale_count},
				  "stale_size_bytes": ${stale_size_bytes},
				  "stale_size_human": "${stale_human}",
				  "threshold_days": ${threshold},
				  "action": "local-model-helper.sh cleanup --remove-stale"
				}
			JSONEOF
		else
			echo "Local models: ${stale_count} stale model(s) using ${stale_human} (unused >${threshold}d). Run: local-model-helper.sh cleanup"
		fi
	fi

	return 0
}

# =============================================================================
# Command: inventory (t1338.5 — show model inventory from DB)
# =============================================================================

cmd_inventory() {
	local json_output=false
	local do_sync=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		--sync)
			do_sync=true
			shift
			;;
		*) shift ;;
		esac
	done

	if ! suppress_stderr command -v sqlite3; then
		print_error "sqlite3 is required for inventory"
		return 2
	fi

	if [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		print_info "No inventory data. Run: local-model-helper.sh setup"
		return 0
	fi

	# Sync after precondition checks pass
	if [[ "$do_sync" == "true" ]]; then
		if sync_model_inventory; then
			print_success "Model inventory synced with disk"
		else
			print_error "Failed to sync model inventory"
			return 1
		fi
	fi

	if [[ "$json_output" == "true" ]]; then
		sqlite3 -json "$LOCAL_USAGE_DB" "SELECT model, file_path, repo_source, size_bytes, quantization, first_seen, last_used, total_requests FROM model_inventory ORDER BY last_used DESC;" 2>/dev/null
		return 0
	fi

	printf "%-35s %10s %8s %8s %12s\n" "MODEL" "SIZE" "QUANT" "REQUESTS" "LAST_USED"
	printf "%-35s %10s %8s %8s %12s\n" "-----" "----" "-----" "--------" "---------"

	sqlite3 -separator $'\t' "$LOCAL_USAGE_DB" \
		"SELECT model, size_bytes, quantization, total_requests, last_used FROM model_inventory ORDER BY last_used DESC;" 2>/dev/null |
		while IFS=$'\t' read -r model size_bytes quant requests last_used; do
			local display_model="$model"
			if [[ ${#display_model} -gt 35 ]]; then
				display_model="${display_model:0:32}..."
			fi
			local size_human
			size_human="$(echo "$size_bytes" | awk '{
				if ($1 >= 1073741824) printf "%.1f GB", $1/1073741824;
				else if ($1 >= 1048576) printf "%.0f MB", $1/1048576;
				else if ($1 > 0) printf "%.0f KB", $1/1024;
				else printf "-";
			}')"
			[[ -z "$quant" ]] && quant="-"
			printf "%-35s %10s %8s %8s %12s\n" \
				"$display_model" "$size_human" "$quant" "$requests" "${last_used%% *}"
		done

	return 0
}

# =============================================================================
# Command: update
# =============================================================================
# Check for a new llama.cpp release and report whether an upgrade is available.
# Does not install automatically — use 'install --update' to upgrade.

cmd_update() {
	local json_output=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		*) shift ;;
		esac
	done

	if ! suppress_stderr command -v curl; then
		print_error "curl is required but not found"
		return 2
	fi

	if ! suppress_stderr command -v jq; then
		print_error "jq is required but not found"
		return 2
	fi

	print_info "Checking latest llama.cpp release..."

	local release_json
	release_json="$(curl -sL "$LLAMA_CPP_API")" || {
		print_error "Failed to fetch llama.cpp release info from GitHub"
		return 1
	}

	local latest_tag
	latest_tag="$(echo "$release_json" | jq -r '.tag_name // empty')"
	if [[ -z "$latest_tag" ]]; then
		print_error "Could not determine latest release tag"
		return 1
	fi

	local latest_date
	latest_date="$(echo "$release_json" | jq -r '.published_at // empty' | cut -c1-10)"

	local current_version="not installed"
	local update_available=false

	if [[ -x "$LLAMA_SERVER_BIN" ]]; then
		current_version="$("$LLAMA_SERVER_BIN" --version 2>/dev/null | head -1 || echo "unknown")"
		# Compare: if current version string does not contain the latest tag, update is available
		if ! echo "$current_version" | grep -qF "$latest_tag"; then
			update_available=true
		fi
	else
		update_available=true
	fi

	if [[ "$json_output" == "true" ]]; then
		printf '{"current":"%s","latest":"%s","latest_date":"%s","update_available":%s}\n' \
			"$current_version" "$latest_tag" "$latest_date" "$update_available"
	else
		echo "llama.cpp update check"
		echo "======================"
		echo "Installed: ${current_version}"
		echo "Latest:    ${latest_tag} (${latest_date})"
		if [[ "$update_available" == "true" ]]; then
			print_info "Update available. Run: local-model-helper.sh install --update"
		else
			print_success "Already up to date."
		fi
	fi

	return 0
}

# =============================================================================
# Command: help
# =============================================================================

cmd_help() {
	cat <<-'HELPEOF'
		local-model-helper.sh - Local AI model inference via llama.cpp

		USAGE:
		  local-model-helper.sh <command> [options]

		COMMANDS:
		  install [--update]            Install/update llama.cpp + huggingface-cli (alias: setup)
		  serve [--model M] [options]   Start llama-server localhost:8080 (alias: start)
		  stop                          Stop running llama-server
		  status [--json]               Show server status and loaded model
		  models [--json]               List downloaded GGUF models with size/last-used
		  search <query> [--limit N]    Search HuggingFace for GGUF models
		  pull <repo> [--quant Q]       Download a GGUF model from HuggingFace (alias: download)
		  recommend [--json]            Hardware-aware model recommendations
		  usage [--since DATE] [--json] Show usage statistics (SQLite)
		  cleanup [options]             Show/remove stale models (>30d threshold)
		  update [--json]               Check for new llama.cpp release
		  inventory [--json] [--sync]   Show model inventory from database
		  nudge [--json]                Session-start stale model check (>5 GB)
		  benchmark --model M           Benchmark a model on local hardware
		  help                          Show this help

		START OPTIONS:
		  --model <file>     Model file (name or path)
		  --port <N>         Server port (default: 8080)
		  --host <addr>      Bind address (default: 127.0.0.1)
		  --ctx-size <N>     Context window (default: 8192)
		  --gpu-layers <N>   GPU layers to offload (default: 99)
		  --threads <N>      CPU threads (default: auto)
		  --no-flash-attn    Disable Flash Attention

		CLEANUP OPTIONS:
		  --remove-stale     Remove models unused for >30 days
		  --remove <file>    Remove a specific model
		  --threshold <N>    Days before a model is considered stale (default: 30)

		EXAMPLES:
		  # First-time install
		  local-model-helper.sh install

		  # Check for a new llama.cpp release
		  local-model-helper.sh update

		  # Get model recommendations for your hardware
		  local-model-helper.sh recommend

		  # Search and pull a model
		  local-model-helper.sh search "qwen3 8b"
		  local-model-helper.sh pull Qwen/Qwen3-8B-GGUF --quant Q4_K_M

		  # Start the server
		  local-model-helper.sh serve --model qwen3-8b-q4_k_m.gguf

		  # Check status
		  local-model-helper.sh status

		  # View usage stats
		  local-model-helper.sh usage

		  # Check for stale models at session start
		  local-model-helper.sh nudge

		  # Clean up old models
		  local-model-helper.sh cleanup

		API:
		  When running, the server exposes an OpenAI-compatible API at:
		    http://localhost:8080/v1

		  curl http://localhost:8080/v1/chat/completions \
		    -H "Content-Type: application/json" \
		    -d '{"model":"local","messages":[{"role":"user","content":"Hello"}]}'

		SEE ALSO:
		  tools/local-models/local-models.md    Full documentation
		  tools/context/model-routing.md        Cost-aware routing (local = free tier)
	HELPEOF
	return 0
}

# =============================================================================
# Main Dispatcher
# =============================================================================

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	# Load config defaults
	load_config

	case "$command" in
	install | setup) cmd_setup "$@" ;;
	serve | start) cmd_start "$@" ;;
	stop) cmd_stop ;;
	status) cmd_status "$@" ;;
	models) cmd_models "$@" ;;
	pull | download) cmd_download "$@" ;;
	search) cmd_search "$@" ;;
	recommend) cmd_recommend "$@" ;;
	cleanup) cmd_cleanup "$@" ;;
	usage) cmd_usage "$@" ;;
	update) cmd_update "$@" ;;
	inventory) cmd_inventory "$@" ;;
	nudge) cmd_nudge "$@" ;;
	benchmark) cmd_benchmark "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		echo "Run 'local-model-helper.sh help' for usage information"
		return 1
		;;
	esac
}

main "$@"
