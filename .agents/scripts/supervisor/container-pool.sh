#!/usr/bin/env bash
# container-pool.sh - Container pool manager for supervisor (t1165.2)
#
# Manages a pool of Docker/OrbStack containers for parallel worker dispatch.
# Each container has its own OAuth token, rate limit tracking, and health state.
#
# Features:
#   - Spawn/destroy containers with configurable image and token injection
#   - Health checks (Docker health + CLI probe)
#   - Round-robin dispatch across healthy containers
#   - Per-container rate limit tracking with cooldown
#   - Auto-scaling: spawn on demand, destroy idle containers
#
# Integration:
#   - dispatch.sh calls pool_select_container() for container-aware routing
#   - pulse.sh calls pool_health_check() periodically
#   - cleanup.sh calls pool_destroy_idle() for resource reclamation
#
# Database tables (in supervisor.db):
#   - container_pool: container registry with health/rate-limit state
#   - container_dispatch_log: per-container dispatch history for round-robin

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly CONTAINER_POOL_IMAGE="${CONTAINER_POOL_IMAGE:-aidevops-worker:latest}"
readonly CONTAINER_POOL_PREFIX="${CONTAINER_POOL_PREFIX:-aidevops-worker}"
readonly CONTAINER_POOL_MAX="${CONTAINER_POOL_MAX:-8}"
readonly CONTAINER_POOL_MIN="${CONTAINER_POOL_MIN:-0}"
readonly CONTAINER_POOL_IDLE_TIMEOUT="${CONTAINER_POOL_IDLE_TIMEOUT:-1800}"              # 30 min
readonly CONTAINER_POOL_HEALTH_INTERVAL="${CONTAINER_POOL_HEALTH_INTERVAL:-120}"         # 2 min
readonly CONTAINER_POOL_RATE_LIMIT_COOLDOWN="${CONTAINER_POOL_RATE_LIMIT_COOLDOWN:-300}" # 5 min
readonly CONTAINER_POOL_HEALTH_TIMEOUT="${CONTAINER_POOL_HEALTH_TIMEOUT:-10}"            # 10 sec

# =============================================================================
# Schema
# =============================================================================

#######################################
# Create container_pool table if not exists (t1165.2)
# Called from ensure_db migration block in database.sh
#######################################
_create_container_pool_schema() {
	db "$SUPERVISOR_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS container_pool (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL UNIQUE,
    image           TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'stopped'
                    CHECK(status IN ('starting','healthy','unhealthy','rate_limited','stopping','stopped','failed')),
    docker_id       TEXT,
    host            TEXT DEFAULT 'local',
    oauth_token_ref TEXT,
    last_health_check TEXT,
    last_dispatch_at TEXT,
    dispatch_count  INTEGER NOT NULL DEFAULT 0,
    rate_limit_until TEXT,
    rate_limit_count INTEGER NOT NULL DEFAULT 0,
    error           TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_container_pool_status ON container_pool(status);
CREATE INDEX IF NOT EXISTS idx_container_pool_host ON container_pool(host);

CREATE TABLE IF NOT EXISTS container_dispatch_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    container_id    TEXT NOT NULL,
    task_id         TEXT NOT NULL,
    dispatched_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    completed_at    TEXT,
    outcome         TEXT,
    FOREIGN KEY (container_id) REFERENCES container_pool(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_cdl_container ON container_dispatch_log(container_id);
CREATE INDEX IF NOT EXISTS idx_cdl_task ON container_dispatch_log(task_id);
SQL
	return 0
}

# =============================================================================
# Container Lifecycle
# =============================================================================

#######################################
# Spawn a new container in the pool
# Args:
#   $1 - container name (optional, auto-generated if empty)
#   --image <image>         Docker image (default: $CONTAINER_POOL_IMAGE)
#   --token-ref <ref>       OAuth token reference (gopass path or env var name)
#   --host <host>           Host to spawn on (default: local)
# Returns: container ID on stdout, 0 on success
#######################################
pool_spawn() {
	local name="" image="$CONTAINER_POOL_IMAGE" token_ref="" host="local"

	# First positional arg is name
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		name="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image="$2"
			shift 2
			;;
		--token-ref)
			token_ref="$2"
			shift 2
			;;
		--host)
			host="$2"
			shift 2
			;;
		*)
			log_error "pool_spawn: unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	# Check pool size limit
	local current_count
	current_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_pool WHERE status NOT IN ('stopped','failed');" 2>/dev/null || echo "0")
	if [[ "$current_count" -ge "$CONTAINER_POOL_MAX" ]]; then
		log_error "Container pool at capacity ($current_count/$CONTAINER_POOL_MAX)"
		return 1
	fi

	# Auto-generate name if not provided
	if [[ -z "$name" ]]; then
		local seq
		seq=$(db "$SUPERVISOR_DB" "SELECT COALESCE(MAX(CAST(SUBSTR(name, LENGTH('${CONTAINER_POOL_PREFIX}-') + 1) AS INTEGER)), 0) + 1 FROM container_pool WHERE name LIKE '${CONTAINER_POOL_PREFIX}-%';" 2>/dev/null || echo "1")
		name="${CONTAINER_POOL_PREFIX}-${seq}"
	fi

	# Check for name collision
	local existing
	existing=$(db "$SUPERVISOR_DB" "SELECT id FROM container_pool WHERE name = '$(sql_escape "$name")';" 2>/dev/null || echo "")
	if [[ -n "$existing" ]]; then
		log_error "Container '$name' already exists (id: $existing)"
		return 1
	fi

	# Generate container ID
	local container_id
	container_id="cpool-$(date +%s)-$$-$((RANDOM % 10000))"

	# Register in DB as 'starting'
	local escaped_id escaped_name escaped_image escaped_token escaped_host
	escaped_id=$(sql_escape "$container_id")
	escaped_name=$(sql_escape "$name")
	escaped_image=$(sql_escape "$image")
	escaped_token=$(sql_escape "$token_ref")
	escaped_host=$(sql_escape "$host")

	db "$SUPERVISOR_DB" "
		INSERT INTO container_pool (id, name, image, status, oauth_token_ref, host)
		VALUES ('$escaped_id', '$escaped_name', '$escaped_image', 'starting', '$escaped_token', '$escaped_host');
	"

	log_info "Spawning container '$name' (id: $container_id, image: $image)"

	# Build docker run command
	local -a docker_args=(
		"run" "-d"
		"--name" "$name"
		"--label" "aidevops.pool=true"
		"--label" "aidevops.pool.id=$container_id"
		"--restart" "unless-stopped"
	)

	# Inject OAuth token if provided
	if [[ -n "$token_ref" ]]; then
		local token_value=""
		# Try gopass first, then env var
		if command -v gopass &>/dev/null; then
			token_value=$(gopass show "$token_ref" 2>/dev/null || echo "")
		fi
		if [[ -z "$token_value" ]]; then
			# Try as env var name
			token_value="${!token_ref:-}"
		fi
		if [[ -n "$token_value" ]]; then
			docker_args+=("-e" "CLAUDE_CODE_OAUTH_TOKEN=$token_value")
		else
			log_warn "OAuth token ref '$token_ref' could not be resolved — container may lack auth"
		fi
	fi

	# Mount common volumes
	docker_args+=(
		"-v" "${HOME}/.aidevops/agents:/home/worker/.aidevops/agents:ro"
		"-v" "${HOME}/.gitconfig:/home/worker/.gitconfig:ro"
	)

	docker_args+=("$image")

	# Spawn container
	local docker_id=""
	if [[ "$host" == "local" ]]; then
		docker_id=$(docker "${docker_args[@]}" 2>&1) || {
			local spawn_error="$docker_id"
			log_error "Failed to spawn container '$name': $spawn_error"
			db "$SUPERVISOR_DB" "UPDATE container_pool SET status='failed', error='$(sql_escape "$spawn_error")' WHERE id='$escaped_id';"
			return 1
		}
	else
		# Remote host — delegate to remote-dispatch-helper.sh
		local remote_helper="${SCRIPT_DIR}/../remote-dispatch-helper.sh"
		if [[ -x "$remote_helper" ]]; then
			docker_id=$("$remote_helper" dispatch-container "$host" "${docker_args[@]}" 2>&1) || {
				local spawn_error="$docker_id"
				log_error "Failed to spawn remote container '$name' on $host: $spawn_error"
				db "$SUPERVISOR_DB" "UPDATE container_pool SET status='failed', error='$(sql_escape "$spawn_error")' WHERE id='$escaped_id';"
				return 1
			}
		else
			log_error "Remote dispatch helper not found — cannot spawn on host '$host'"
			db "$SUPERVISOR_DB" "UPDATE container_pool SET status='failed', error='remote-dispatch-helper.sh not found' WHERE id='$escaped_id';"
			return 1
		fi
	fi

	# Update DB with docker ID and mark healthy
	db "$SUPERVISOR_DB" "
		UPDATE container_pool
		SET docker_id = '$(sql_escape "$docker_id")',
		    status = 'healthy',
		    last_health_check = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = '$escaped_id';
	"

	log_success "Container '$name' spawned (docker_id: ${docker_id:0:12})"
	echo "$container_id"
	return 0
}

#######################################
# Destroy a container from the pool
# Args:
#   $1 - container name or ID
#   --force    Force removal even if running tasks
# Returns: 0 on success
#######################################
pool_destroy() {
	local target="${1:-}"
	local force=false
	shift || true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$target" ]]; then
		log_error "Usage: pool_destroy <container-name-or-id> [--force]"
		return 1
	fi

	ensure_db

	# Look up container by name or ID
	local container_row
	container_row=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, name, docker_id, host, status
		FROM container_pool
		WHERE id = '$(sql_escape "$target")' OR name = '$(sql_escape "$target")'
		LIMIT 1;
	" 2>/dev/null || echo "")

	if [[ -z "$container_row" ]]; then
		log_error "Container not found: $target"
		return 1
	fi

	local cid cname cdocker_id chost cstatus
	IFS=$'\t' read -r cid cname cdocker_id chost cstatus <<<"$container_row"

	# Check for active dispatches unless --force
	if [[ "$force" != "true" ]]; then
		local active_dispatches
		active_dispatches=$(db "$SUPERVISOR_DB" "
			SELECT COUNT(*) FROM container_dispatch_log
			WHERE container_id = '$(sql_escape "$cid")' AND completed_at IS NULL;
		" 2>/dev/null || echo "0")
		if [[ "$active_dispatches" -gt 0 ]]; then
			log_error "Container '$cname' has $active_dispatches active dispatches — use --force to override"
			return 1
		fi
	fi

	# Mark as stopping
	db "$SUPERVISOR_DB" "UPDATE container_pool SET status='stopping', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id='$(sql_escape "$cid")';"

	log_info "Destroying container '$cname' (docker_id: ${cdocker_id:0:12})"

	# Stop and remove Docker container
	if [[ -n "$cdocker_id" ]]; then
		if [[ "$chost" == "local" ]]; then
			docker stop "$cdocker_id" 2>/dev/null || true
			docker rm -f "$cdocker_id" 2>/dev/null || true
		else
			local remote_helper="${SCRIPT_DIR}/../remote-dispatch-helper.sh"
			if [[ -x "$remote_helper" ]]; then
				"$remote_helper" cleanup-container "$chost" "$cdocker_id" 2>/dev/null || true
			fi
		fi
	fi

	# Mark as stopped
	db "$SUPERVISOR_DB" "UPDATE container_pool SET status='stopped', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id='$(sql_escape "$cid")';"

	log_success "Container '$cname' destroyed"
	return 0
}

# =============================================================================
# Health Checks
# =============================================================================

#######################################
# Run health check on a single container
# Args:
#   $1 - container ID or name
# Returns: 0 if healthy, 1 if unhealthy
#######################################
pool_health_check_one() {
	local target="$1"

	local container_row
	container_row=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, name, docker_id, host, status
		FROM container_pool
		WHERE (id = '$(sql_escape "$target")' OR name = '$(sql_escape "$target")')
		  AND status NOT IN ('stopped','failed')
		LIMIT 1;
	" 2>/dev/null || echo "")

	if [[ -z "$container_row" ]]; then
		return 1
	fi

	local cid cname cdocker_id chost cstatus
	IFS=$'\t' read -r cid cname cdocker_id chost cstatus <<<"$container_row"

	local is_healthy=true
	local health_error=""

	# Check 1: Docker container is running
	if [[ "$chost" == "local" ]]; then
		local docker_state
		docker_state=$(docker inspect --format='{{.State.Status}}' "$cdocker_id" 2>/dev/null || echo "missing")
		if [[ "$docker_state" != "running" ]]; then
			is_healthy=false
			health_error="docker_state=$docker_state"
		fi
	fi

	# Check 2: If rate-limited, check if cooldown has expired
	if [[ "$cstatus" == "rate_limited" ]]; then
		local rate_limit_until
		rate_limit_until=$(db "$SUPERVISOR_DB" "SELECT COALESCE(rate_limit_until, '') FROM container_pool WHERE id='$(sql_escape "$cid")';" 2>/dev/null || echo "")
		if [[ -n "$rate_limit_until" ]]; then
			local now_ts
			now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
			if [[ "$now_ts" < "$rate_limit_until" ]]; then
				# Still rate-limited — not healthy for dispatch but container is alive
				db "$SUPERVISOR_DB" "UPDATE container_pool SET last_health_check=strftime('%Y-%m-%dT%H:%M:%SZ','now'), updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id='$(sql_escape "$cid")';"
				return 1
			else
				# Cooldown expired — clear rate limit
				log_info "Container '$cname' rate limit cooldown expired — marking healthy"
			fi
		fi
	fi

	# Update health status
	local new_status="healthy"
	if [[ "$is_healthy" != "true" ]]; then
		new_status="unhealthy"
	fi

	db "$SUPERVISOR_DB" "
		UPDATE container_pool
		SET status = '$new_status',
		    last_health_check = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
		    error = '$(sql_escape "$health_error")',
		    rate_limit_until = CASE WHEN '$new_status' = 'healthy' THEN NULL ELSE rate_limit_until END,
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = '$(sql_escape "$cid")';
	"

	if [[ "$is_healthy" == "true" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Run health checks on all active containers in the pool
# Returns: count of healthy containers on stdout
#######################################
pool_health_check_all() {
	ensure_db

	local container_ids
	container_ids=$(db "$SUPERVISOR_DB" "
		SELECT id FROM container_pool
		WHERE status NOT IN ('stopped','failed')
		ORDER BY name;
	" 2>/dev/null || echo "")

	if [[ -z "$container_ids" ]]; then
		echo "0"
		return 0
	fi

	local healthy_count=0
	local total_count=0
	while IFS= read -r cid; do
		[[ -z "$cid" ]] && continue
		total_count=$((total_count + 1))
		if pool_health_check_one "$cid"; then
			healthy_count=$((healthy_count + 1))
		fi
	done <<<"$container_ids"

	log_info "Pool health: $healthy_count/$total_count containers healthy"
	echo "$healthy_count"
	return 0
}

# =============================================================================
# Round-Robin Dispatch
# =============================================================================

#######################################
# Select the next container for dispatch using round-robin
# Picks the healthy container with the oldest last_dispatch_at timestamp,
# skipping rate-limited containers.
#
# Args:
#   --host <host>   Filter by host (optional)
# Returns: container ID on stdout, 0 if found, 1 if no container available
#######################################
pool_select_container() {
	local host_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--host)
			host_filter="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	ensure_db

	# Select healthy container with oldest dispatch time (round-robin)
	local host_clause=""
	if [[ -n "$host_filter" ]]; then
		host_clause="AND host = '$(sql_escape "$host_filter")'"
	fi

	local selected
	selected=$(db "$SUPERVISOR_DB" "
		SELECT id FROM container_pool
		WHERE status = 'healthy'
		  AND (rate_limit_until IS NULL OR rate_limit_until <= strftime('%Y-%m-%dT%H:%M:%SZ','now'))
		  $host_clause
		ORDER BY COALESCE(last_dispatch_at, '1970-01-01T00:00:00Z') ASC
		LIMIT 1;
	" 2>/dev/null || echo "")

	if [[ -z "$selected" ]]; then
		log_verbose "No healthy container available for dispatch"
		return 1
	fi

	echo "$selected"
	return 0
}

#######################################
# Record a dispatch to a container (updates round-robin state)
# Args:
#   $1 - container ID
#   $2 - task ID
#######################################
pool_record_dispatch() {
	local container_id="$1"
	local task_id="$2"

	db "$SUPERVISOR_DB" "
		INSERT INTO container_dispatch_log (container_id, task_id)
		VALUES ('$(sql_escape "$container_id")', '$(sql_escape "$task_id")');
	"

	db "$SUPERVISOR_DB" "
		UPDATE container_pool
		SET last_dispatch_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
		    dispatch_count = dispatch_count + 1,
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = '$(sql_escape "$container_id")';
	"

	return 0
}

#######################################
# Record dispatch completion for a container
# Args:
#   $1 - container ID
#   $2 - task ID
#   $3 - outcome (e.g., "complete", "failed", "rate_limited")
#######################################
pool_record_completion() {
	local container_id="$1"
	local task_id="$2"
	local outcome="$3"

	db "$SUPERVISOR_DB" "
		UPDATE container_dispatch_log
		SET completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
		    outcome = '$(sql_escape "$outcome")'
		WHERE container_id = '$(sql_escape "$container_id")'
		  AND task_id = '$(sql_escape "$task_id")'
		  AND completed_at IS NULL;
	"

	# If rate-limited, mark container with cooldown
	if [[ "$outcome" == "rate_limited" ]]; then
		pool_mark_rate_limited "$container_id"
	fi

	return 0
}

# =============================================================================
# Rate Limit Tracking
# =============================================================================

#######################################
# Mark a container as rate-limited with cooldown
# Args:
#   $1 - container ID
#   $2 - cooldown seconds (optional, default: CONTAINER_POOL_RATE_LIMIT_COOLDOWN)
#######################################
pool_mark_rate_limited() {
	local container_id="$1"
	local cooldown="${2:-$CONTAINER_POOL_RATE_LIMIT_COOLDOWN}"

	db "$SUPERVISOR_DB" "
		UPDATE container_pool
		SET status = 'rate_limited',
		    rate_limit_until = strftime('%Y-%m-%dT%H:%M:%SZ','now','+${cooldown} seconds'),
		    rate_limit_count = rate_limit_count + 1,
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = '$(sql_escape "$container_id")';
	"

	local cname
	cname=$(db "$SUPERVISOR_DB" "SELECT name FROM container_pool WHERE id='$(sql_escape "$container_id")';" 2>/dev/null || echo "$container_id")
	log_warn "Container '$cname' marked rate_limited (cooldown: ${cooldown}s)"
	return 0
}

#######################################
# Clear rate limit on a container (manual override)
# Args:
#   $1 - container ID or name
#######################################
pool_clear_rate_limit() {
	local target="$1"

	db "$SUPERVISOR_DB" "
		UPDATE container_pool
		SET status = 'healthy',
		    rate_limit_until = NULL,
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE (id = '$(sql_escape "$target")' OR name = '$(sql_escape "$target")')
		  AND status = 'rate_limited';
	"

	log_info "Rate limit cleared for container '$target'"
	return 0
}

# =============================================================================
# Pool Management
# =============================================================================

#######################################
# Destroy idle containers (no dispatch in CONTAINER_POOL_IDLE_TIMEOUT seconds)
# Respects CONTAINER_POOL_MIN — won't destroy below minimum pool size.
# Args:
#   --dry-run   Show what would be destroyed without acting
# Returns: count of destroyed containers
#######################################
pool_destroy_idle() {
	local dry_run=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		*) shift ;;
		esac
	done

	ensure_db

	local healthy_count
	healthy_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_pool WHERE status IN ('healthy','rate_limited');" 2>/dev/null || echo "0")

	# Don't destroy below minimum
	local destroyable=$((healthy_count - CONTAINER_POOL_MIN))
	if [[ "$destroyable" -le 0 ]]; then
		log_verbose "Pool at minimum size ($healthy_count/$CONTAINER_POOL_MIN) — no idle cleanup"
		echo "0"
		return 0
	fi

	# Find idle containers (no dispatch in timeout window, no active tasks)
	local idle_containers
	idle_containers=$(db "$SUPERVISOR_DB" "
		SELECT cp.id, cp.name
		FROM container_pool cp
		WHERE cp.status IN ('healthy','rate_limited')
		  AND (cp.last_dispatch_at IS NULL
		       OR cp.last_dispatch_at < strftime('%Y-%m-%dT%H:%M:%SZ','now','-${CONTAINER_POOL_IDLE_TIMEOUT} seconds'))
		  AND NOT EXISTS (
		      SELECT 1 FROM container_dispatch_log cdl
		      WHERE cdl.container_id = cp.id AND cdl.completed_at IS NULL
		  )
		ORDER BY COALESCE(cp.last_dispatch_at, cp.created_at) ASC
		LIMIT $destroyable;
	" 2>/dev/null || echo "")

	if [[ -z "$idle_containers" ]]; then
		echo "0"
		return 0
	fi

	local destroyed=0
	while IFS='|' read -r cid cname; do
		[[ -z "$cid" ]] && continue
		if [[ "$dry_run" == "true" ]]; then
			log_info "[dry-run] Would destroy idle container: $cname ($cid)"
		else
			pool_destroy "$cid" --force 2>/dev/null && destroyed=$((destroyed + 1))
		fi
	done <<<"$idle_containers"

	if [[ "$destroyed" -gt 0 ]]; then
		log_info "Destroyed $destroyed idle container(s)"
	fi
	echo "$destroyed"
	return 0
}

#######################################
# List all containers in the pool
# Args:
#   --status <status>   Filter by status
#   --format json       Output as JSON
# Returns: formatted table on stdout
#######################################
pool_list() {
	local status_filter="" format="table"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--status)
			status_filter="$2"
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	ensure_db

	local where_clause=""
	if [[ -n "$status_filter" ]]; then
		where_clause="WHERE status = '$(sql_escape "$status_filter")'"
	fi

	if [[ "$format" == "json" ]]; then
		db "$SUPERVISOR_DB" ".mode json" "
			SELECT id, name, image, status, host, docker_id,
			       dispatch_count, rate_limit_count,
			       last_dispatch_at, last_health_check,
			       rate_limit_until, error, created_at
			FROM container_pool $where_clause
			ORDER BY name;
		"
	else
		echo ""
		echo "Container Pool:"
		echo "==============="
		db -column -header "$SUPERVISOR_DB" "
			SELECT name AS Name,
			       status AS Status,
			       host AS Host,
			       dispatch_count AS Dispatches,
			       rate_limit_count AS 'Rate Limits',
			       COALESCE(SUBSTR(last_dispatch_at, 12, 8), '-') AS 'Last Dispatch',
			       COALESCE(SUBSTR(rate_limit_until, 12, 8), '-') AS 'RL Until',
			       COALESCE(SUBSTR(error, 1, 30), '-') AS Error
			FROM container_pool $where_clause
			ORDER BY name;
		"
	fi

	# Summary line
	local total healthy rl stopped
	total=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_pool $where_clause;" 2>/dev/null || echo "0")
	healthy=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_pool WHERE status='healthy';" 2>/dev/null || echo "0")
	rl=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_pool WHERE status='rate_limited';" 2>/dev/null || echo "0")
	stopped=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_pool WHERE status='stopped';" 2>/dev/null || echo "0")

	echo ""
	echo "Total: $total | Healthy: $healthy | Rate-limited: $rl | Stopped: $stopped"
	return 0
}

#######################################
# Get pool statistics
# Returns: JSON object with pool stats
#######################################
pool_stats() {
	ensure_db

	local total healthy unhealthy rate_limited stopped failed
	total=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_pool;" 2>/dev/null || echo "0")
	healthy=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_pool WHERE status='healthy';" 2>/dev/null || echo "0")
	unhealthy=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_pool WHERE status='unhealthy';" 2>/dev/null || echo "0")
	rate_limited=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_pool WHERE status='rate_limited';" 2>/dev/null || echo "0")
	stopped=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_pool WHERE status='stopped';" 2>/dev/null || echo "0")
	failed=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_pool WHERE status='failed';" 2>/dev/null || echo "0")

	local total_dispatches avg_dispatches
	total_dispatches=$(db "$SUPERVISOR_DB" "SELECT COALESCE(SUM(dispatch_count), 0) FROM container_pool;" 2>/dev/null || echo "0")
	avg_dispatches=$(db "$SUPERVISOR_DB" "SELECT COALESCE(ROUND(AVG(dispatch_count), 1), 0) FROM container_pool WHERE status NOT IN ('stopped','failed');" 2>/dev/null || echo "0")

	local active_tasks
	active_tasks=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM container_dispatch_log WHERE completed_at IS NULL;" 2>/dev/null || echo "0")

	cat <<EOF
{
  "total": $total,
  "healthy": $healthy,
  "unhealthy": $unhealthy,
  "rate_limited": $rate_limited,
  "stopped": $stopped,
  "failed": $failed,
  "total_dispatches": $total_dispatches,
  "avg_dispatches_per_container": $avg_dispatches,
  "active_tasks": $active_tasks,
  "pool_max": $CONTAINER_POOL_MAX,
  "pool_min": $CONTAINER_POOL_MIN
}
EOF
	return 0
}

# =============================================================================
# CLI Commands (routed from supervisor-helper.sh)
# =============================================================================

#######################################
# Main pool command router
# Usage: supervisor-helper.sh pool <subcommand> [args]
#######################################
cmd_pool() {
	local subcmd="${1:-status}"
	shift || true

	case "$subcmd" in
	spawn) pool_spawn "$@" ;;
	destroy) pool_destroy "$@" ;;
	list) pool_list "$@" ;;
	status | stats) pool_stats "$@" ;;
	health) pool_health_check_all "$@" ;;
	select) pool_select_container "$@" ;;
	rate-limit)
		local _rl_target="${1:-}"
		local _rl_action="${2:-set}"
		if [[ -z "$_rl_target" ]]; then
			log_error "Usage: pool rate-limit <container> [set|clear]"
			return 1
		fi
		case "$_rl_action" in
		set) pool_mark_rate_limited "$_rl_target" "${3:-}" ;;
		clear) pool_clear_rate_limit "$_rl_target" ;;
		*)
			log_error "Unknown rate-limit action: $_rl_action (use set|clear)"
			return 1
			;;
		esac
		;;
	cleanup) pool_destroy_idle "$@" ;;
	help)
		cat <<'EOF'
supervisor-helper.sh pool <subcommand> [args]

Subcommands:
  spawn [name] [--image X] [--token-ref X] [--host X]  Spawn a new container
  destroy <name|id> [--force]                           Destroy a container
  list [--status X] [--format json]                     List containers
  status                                                Pool statistics (JSON)
  health                                                Run health checks on all containers
  select [--host X]                                     Select next container (round-robin)
  rate-limit <container> [set|clear] [cooldown_secs]    Manage rate limits
  cleanup [--dry-run]                                   Destroy idle containers
  help                                                  Show this help
EOF
		;;
	*)
		log_error "Unknown pool subcommand: $subcmd"
		return 1
		;;
	esac
	return $?
}
