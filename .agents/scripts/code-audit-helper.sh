#!/usr/bin/env bash
set -euo pipefail

# Code Audit Helper - Audit trend tracking and regression detection
#
# Usage:
#   code-audit-helper.sh init                    # Initialize audit database
#   code-audit-helper.sh snapshot <source>       # Record snapshot after audit run
#   code-audit-helper.sh trend [--source <src>]  # Show WoW/MoM trends
#   code-audit-helper.sh check-regression        # Check for regressions (>20% increase)

# Database location
AUDIT_DB="${AUDIT_DB:-$HOME/.aidevops/.agent-workspace/work/code-audit/audit.db}"

# Logging functions
log_info() {
	echo -e "\033[0;32m[INFO]\033[0m $*" >&2
	return 0
}

log_warn() {
	echo -e "\033[1;33m[WARN]\033[0m $*" >&2
	return 0
}

log_error() {
	echo -e "\033[0;31m[ERROR]\033[0m $*" >&2
	return 0
}

# Ensure database directory exists
ensure_db_dir() {
	local db_dir
	db_dir="$(dirname "$AUDIT_DB")"
	if [[ ! -d "$db_dir" ]]; then
		mkdir -p "$db_dir"
	fi
	return 0
}

# Initialize or migrate database schema
init_db() {
	ensure_db_dir

	# Check if audit_snapshots table exists
	local table_exists
	table_exists=$(sqlite3 "$AUDIT_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='audit_snapshots';" 2>/dev/null || echo "")

	if [[ -z "$table_exists" ]]; then
		log_info "Creating audit_snapshots table..."
		sqlite3 "$AUDIT_DB" <<-'SQL'
			PRAGMA journal_mode=WAL;
			PRAGMA busy_timeout=5000;

			CREATE TABLE IF NOT EXISTS audit_snapshots (
			    id                INTEGER PRIMARY KEY AUTOINCREMENT,
			    date              TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
			    source            TEXT NOT NULL,
			    total_findings    INTEGER NOT NULL DEFAULT 0,
			    critical_count    INTEGER NOT NULL DEFAULT 0,
			    high_count        INTEGER NOT NULL DEFAULT 0,
			    medium_count      INTEGER NOT NULL DEFAULT 0,
			    low_count         INTEGER NOT NULL DEFAULT 0,
			    false_positives   INTEGER NOT NULL DEFAULT 0,
			    tasks_created     INTEGER NOT NULL DEFAULT 0
			);
			CREATE INDEX IF NOT EXISTS idx_snapshots_date ON audit_snapshots(date);
			CREATE INDEX IF NOT EXISTS idx_snapshots_source ON audit_snapshots(source);
		SQL
		log_info "audit_snapshots table created successfully"
	else
		log_info "audit_snapshots table already exists"
	fi

	return 0
}

# Record a snapshot after an audit run
# Usage: snapshot <source> [--total N] [--critical N] [--high N] [--medium N] [--low N] [--false-positives N] [--tasks N]
cmd_snapshot() {
	local source=""
	local total=0
	local critical=0
	local high=0
	local medium=0
	local low=0
	local false_positives=0
	local tasks=0

	if [[ $# -lt 1 ]]; then
		log_error "Usage: snapshot <source> [--total N] [--critical N] [--high N] [--medium N] [--low N] [--false-positives N] [--tasks N]"
		return 1
	fi

	source="$1"
	shift

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--total)
			total="$2"
			shift 2
			;;
		--critical)
			critical="$2"
			shift 2
			;;
		--high)
			high="$2"
			shift 2
			;;
		--medium)
			medium="$2"
			shift 2
			;;
		--low)
			low="$2"
			shift 2
			;;
		--false-positives)
			false_positives="$2"
			shift 2
			;;
		--tasks)
			tasks="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	init_db

	# Escape single quotes in source to prevent SQL injection
	local escaped_source
	escaped_source=$(printf "%s" "$source" | sed "s/'/''/g")

	sqlite3 "$AUDIT_DB" <<-SQL
		INSERT INTO audit_snapshots (source, total_findings, critical_count, high_count, medium_count, low_count, false_positives, tasks_created)
		VALUES ('$escaped_source', $total, $critical, $high, $medium, $low, $false_positives, $tasks);
	SQL

	log_info "Snapshot recorded for source: $source (total: $total, critical: $critical, high: $high, medium: $medium, low: $low)"
	return 0
}

# Calculate trend deltas (WoW and MoM)
# Usage: trend [--source <source>]
cmd_trend() {
	local source=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--source)
			source="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	init_db

	local source_filter=""
	if [[ -n "$source" ]]; then
		# Escape single quotes in source to prevent SQL injection
		local escaped_source
		escaped_source=$(printf "%s" "$source" | sed "s/'/''/g")
		source_filter="WHERE source = '$escaped_source'"
	fi

	# Get current snapshot (most recent)
	local current
	current=$(sqlite3 -separator '|' "$AUDIT_DB" "
		SELECT date, source, total_findings, critical_count, high_count, medium_count, low_count
		FROM audit_snapshots
		$source_filter
		ORDER BY date DESC
		LIMIT 1;
	" 2>/dev/null || echo "")

	if [[ -z "$current" ]]; then
		log_warn "No snapshots found"
		return 0
	fi

	# Initialize variables to default values before read to handle missing columns
	local current_date="" current_source="" current_total=0 current_critical=0 current_high=0 current_medium=0 current_low=0
	IFS='|' read -r current_date current_source current_total current_critical current_high current_medium current_low <<<"$current"

	# Get week-ago snapshot (7 days ago)
	local week_ago_date
	week_ago_date=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

	local week_ago=""
	if [[ -n "$week_ago_date" ]]; then
		week_ago=$(sqlite3 -separator '|' "$AUDIT_DB" "
			SELECT total_findings, critical_count, high_count, medium_count, low_count
			FROM audit_snapshots
			WHERE source = '$current_source' AND date <= '$week_ago_date'
			ORDER BY date DESC
			LIMIT 1;
		" 2>/dev/null || echo "")
	fi

	# Get month-ago snapshot (30 days ago)
	local month_ago_date
	month_ago_date=$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

	local month_ago=""
	if [[ -n "$month_ago_date" ]]; then
		month_ago=$(sqlite3 -separator '|' "$AUDIT_DB" "
			SELECT total_findings, critical_count, high_count, medium_count, low_count
			FROM audit_snapshots
			WHERE source = '$current_source' AND date <= '$month_ago_date'
			ORDER BY date DESC
			LIMIT 1;
		" 2>/dev/null || echo "")
	fi

	# Display current state
	echo "=== Audit Trend Report ==="
	echo "Source: $current_source"
	echo "Date: $current_date"
	echo ""
	echo "Current Findings:"
	echo "  Total: $current_total"
	echo "  Critical: $current_critical"
	echo "  High: $current_high"
	echo "  Medium: $current_medium"
	echo "  Low: $current_low"
	echo ""

	# Week-over-week delta
	if [[ -n "$week_ago" ]]; then
		# Initialize variables to default values before read to handle missing columns
		local week_total=0 week_critical=0 week_high=0 week_medium=0 week_low=0
		IFS='|' read -r week_total week_critical week_high week_medium week_low <<<"$week_ago"

		local wow_total_delta=$((current_total - week_total))
		local wow_critical_delta=$((current_critical - week_critical))
		local wow_high_delta=$((current_high - week_high))
		local wow_medium_delta=$((current_medium - week_medium))
		local wow_low_delta=$((current_low - week_low))

		echo "Week-over-Week Change:"
		echo "  Total: $wow_total_delta (was: $week_total)"
		echo "  Critical: $wow_critical_delta (was: $week_critical)"
		echo "  High: $wow_high_delta (was: $week_high)"
		echo "  Medium: $wow_medium_delta (was: $week_medium)"
		echo "  Low: $wow_low_delta (was: $week_low)"
		echo ""
	else
		echo "Week-over-Week Change: No data from 7 days ago"
		echo ""
	fi

	# Month-over-month delta
	if [[ -n "$month_ago" ]]; then
		# Initialize variables to default values before read to handle missing columns
		local month_total=0 month_critical=0 month_high=0 month_medium=0 month_low=0
		IFS='|' read -r month_total month_critical month_high month_medium month_low <<<"$month_ago"

		local mom_total_delta=$((current_total - month_total))
		local mom_critical_delta=$((current_critical - month_critical))
		local mom_high_delta=$((current_high - month_high))
		local mom_medium_delta=$((current_medium - month_medium))
		local mom_low_delta=$((current_low - month_low))

		echo "Month-over-Month Change:"
		echo "  Total: $mom_total_delta (was: $month_total)"
		echo "  Critical: $mom_critical_delta (was: $month_critical)"
		echo "  High: $mom_high_delta (was: $month_high)"
		echo "  Medium: $mom_medium_delta (was: $month_medium)"
		echo "  Low: $mom_low_delta (was: $month_low)"
	else
		echo "Month-over-Month Change: No data from 30 days ago"
	fi

	return 0
}

# Check for regressions (>20% increase in findings)
# Returns exit code 1 if regression detected, 0 otherwise
cmd_check_regression() {
	init_db

	# Get all sources with snapshots
	local sources
	sources=$(sqlite3 "$AUDIT_DB" "SELECT DISTINCT source FROM audit_snapshots ORDER BY source;" 2>/dev/null || echo "")

	if [[ -z "$sources" ]]; then
		log_info "No snapshots found for regression check"
		return 0
	fi

	local regression_found=0

	while IFS= read -r source; do
		[[ -z "$source" ]] && continue

		# Get current and previous snapshot
		local snapshots
		snapshots=$(sqlite3 -separator '|' "$AUDIT_DB" "
			SELECT date, total_findings, critical_count, high_count
			FROM audit_snapshots
			WHERE source = '$source'
			ORDER BY date DESC
			LIMIT 2;
		" 2>/dev/null || echo "")

		local line_count
		line_count=$(echo "$snapshots" | wc -l | tr -d ' ')

		if [[ "$line_count" -lt 2 ]]; then
			continue
		fi

		local current_line
		local previous_line
		current_line=$(echo "$snapshots" | head -1)
		previous_line=$(echo "$snapshots" | tail -1)

		# Initialize variables to default values before read to handle missing columns
		local current_date="" current_total=0 current_critical=0 current_high=0
		local _previous_date="" previous_total=0 previous_critical=0 previous_high=0
		IFS='|' read -r current_date current_total current_critical current_high <<<"$current_line"
		IFS='|' read -r _previous_date previous_total previous_critical previous_high <<<"$previous_line"

		# Skip if previous total is 0 (avoid division by zero)
		if [[ "$previous_total" -eq 0 ]]; then
			continue
		fi

		# Calculate percentage increase
		local delta=$((current_total - previous_total))
		local percent_increase=$((delta * 100 / previous_total))

		# Check for >20% increase
		if [[ "$percent_increase" -gt 20 ]]; then
			log_warn "REGRESSION DETECTED: $source - findings increased by ${percent_increase}% (${previous_total} -> ${current_total})"
			regression_found=1
		fi

		# Also check critical/high severity increases
		if [[ "$previous_critical" -gt 0 ]]; then
			local critical_delta=$((current_critical - previous_critical))
			local critical_percent=$((critical_delta * 100 / previous_critical))
			if [[ "$critical_percent" -gt 20 ]]; then
				log_warn "REGRESSION DETECTED: $source - critical findings increased by ${critical_percent}% (${previous_critical} -> ${current_critical})"
				regression_found=1
			fi
		elif [[ "$current_critical" -gt 0 && "$previous_critical" -eq 0 ]]; then
			log_warn "REGRESSION DETECTED: $source - new critical findings appeared: $current_critical"
			regression_found=1
		fi

		if [[ "$previous_high" -gt 0 ]]; then
			local high_delta=$((current_high - previous_high))
			local high_percent=$((high_delta * 100 / previous_high))
			if [[ "$high_percent" -gt 20 ]]; then
				log_warn "REGRESSION DETECTED: $source - high severity findings increased by ${high_percent}% (${previous_high} -> ${current_high})"
				regression_found=1
			fi
		elif [[ "$current_high" -gt 0 && "$previous_high" -eq 0 ]]; then
			log_warn "REGRESSION DETECTED: $source - new high severity findings appeared: $current_high"
			regression_found=1
		fi

	done <<<"$sources"

	if [[ "$regression_found" -eq 0 ]]; then
		log_info "No regressions detected"
	fi

	return "$regression_found"
}

# Main command dispatcher
main() {
	if [[ $# -lt 1 ]]; then
		cat <<-'USAGE'
			Usage: code-audit-helper.sh <command> [options]

			Commands:
			  init                                  Initialize audit database
			  snapshot <source> [options]           Record snapshot after audit run
			  trend [--source <source>]             Show WoW/MoM trends
			  check-regression                      Check for regressions (>20% increase)

			Snapshot Options:
			  --total N              Total findings count
			  --critical N           Critical severity count
			  --high N               High severity count
			  --medium N             Medium severity count
			  --low N                Low severity count
			  --false-positives N    False positive count
			  --tasks N              Tasks created count

			Examples:
			  code-audit-helper.sh init
			  code-audit-helper.sh snapshot sonarcloud --total 42 --critical 2 --high 5 --medium 15 --low 20
			  code-audit-helper.sh trend --source sonarcloud
			  code-audit-helper.sh check-regression
		USAGE
		return 0
	fi

	local cmd="$1"
	shift

	case "$cmd" in
	init)
		init_db
		;;
	snapshot)
		cmd_snapshot "$@"
		;;
	trend)
		cmd_trend "$@"
		;;
	check-regression)
		cmd_check_regression
		;;
	*)
		log_error "Unknown command: $cmd"
		return 1
		;;
	esac
}

main "$@"
