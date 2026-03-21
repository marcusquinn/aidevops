#!/usr/bin/env bash
# plans-cleanup-helper.sh — Archive completed plans from PLANS.md
# Removes plans where all referenced tasks are completed and issues are closed
#
# Usage:
#   plans-cleanup-helper.sh check          Show which plans are completed
#   plans-cleanup-helper.sh archive        Move completed plans to archive section
#   plans-cleanup-helper.sh remove         Remove completed plans entirely
#   plans-cleanup-helper.sh status         Show plan completion summary

set -euo pipefail

PLANS_FILE="${PLANS_FILE:-todo/PLANS.md}"
TODO_FILE="${TODO_FILE:-TODO.md}"
ARCHIVE_FILE="${ARCHIVE_FILE:-todo/PLANS-ARCHIVE.md}"

get_plan_sections() {
	grep -n "^### \[" "$PLANS_FILE" 2>/dev/null || true
}

get_plan_status() {
	local line="$1"
	sed -n "$((line+1)),$((line+5))p" "$PLANS_FILE" | grep "Status:" | head -1 | sed 's/.*Status:\s*//'
}

get_plan_todos() {
	local line="$1"
	sed -n "$((line+1)),$((line+10))p" "$PLANS_FILE" | grep -oE "t[0-9]+" | sort -u
}

check_todo_completed() {
	local todo_id="$1"
	grep -c "\[x\].*${todo_id}" "$TODO_FILE" 2>/dev/null || echo 0
}

check_plan_completed() {
	local line="$1"
	local status
	status=$(get_plan_status "$line")

	if echo "$status" | grep -qi "completed"; then
		echo "completed"
		return
	fi

	if echo "$status" | grep -qiE "blocked|in.progress"; then
		echo "active"
		return
	fi

	local todos
	todos=$(get_plan_todos "$line")
	if [ -z "$todos" ]; then
		echo "no_todos"
		return
	fi

	local all_done=true
	for todo in $todos; do
		local count
		count=$(check_todo_completed "$todo")
		if [ "$count" -eq 0 ]; then
			all_done=false
			break
		fi
	done

	if [ "$all_done" = "true" ]; then
		echo "all_todos_done"
	else
		echo "has_pending"
	fi
}

cmd_check() {
	echo "## Plan Completion Status"
	echo ""
	local total=0
	local completed=0
	local active=0
	local pending=0

	while IFS= read -r header_line; do
		local line_num
		line_num=$(echo "$header_line" | cut -d: -f1)
		local title
		title=$(echo "$header_line" | cut -d: -f2- | sed 's/^### //')
		local status
		status=$(check_plan_completed "$line_num")
		total=$((total + 1))

		case "$status" in
			completed|all_todos_done)
				completed=$((completed + 1))
				echo "✅ $title"
				;;
			active)
				active=$((active + 1))
				echo "🔄 $title"
				;;
			has_pending)
				pending=$((pending + 1))
				echo "⏳ $title"
				;;
			no_todos)
				echo "❓ $title (no TODOs found)"
				;;
		esac
	done < <(get_plan_sections)

	echo ""
	echo "Summary: $completed/$total completed, $active active, $pending pending"
}

cmd_archive() {
	if [ ! -f "$PLANS_FILE" ]; then
		echo "ERROR: $PLANS_FILE not found" >&2
		exit 1
	fi

	if [ ! -f "$ARCHIVE_FILE" ]; then
		echo "# Archived Plans" > "$ARCHIVE_FILE"
		echo "" >> "$ARCHIVE_FILE"
		echo "Completed plans moved from PLANS.md during setup/cleanup." >> "$ARCHIVE_FILE"
		echo "" >> "$ARCHIVE_FILE"
	fi

	local archived=0
	local temp_file
	temp_file=$(mktemp)
	cp "$PLANS_FILE" "$temp_file"

	while IFS= read -r header_line; do
		local line_num
		line_num=$(echo "$header_line" | cut -d: -f1)
		local status
		status=$(check_plan_completed "$line_num")

		if [ "$status" = "completed" ] || [ "$status" = "all_todos_done" ]; then
			local title
			title=$(echo "$header_line" | cut -d: -f2- | sed 's/^### //')

			local next_header
			next_header=$(tail -n +$((line_num + 1)) "$temp_file" | grep -n "^### \[" | head -1 | cut -d: -f1)
			if [ -n "$next_header" ]; then
				local end_line=$((line_num + next_header - 1))
			else
				local end_line
				end_line=$(wc -l < "$temp_file")
			fi

			echo "" >> "$ARCHIVE_FILE"
			sed -n "${line_num},${end_line}p" "$temp_file" >> "$ARCHIVE_FILE"

			sed -i "${line_num},${end_line}d" "$temp_file" 2>/dev/null || true
			archived=$((archived + 1))
			echo "Archived: $title"
		fi
	done < <(get_plan_sections)

	mv "$temp_file" "$PLANS_FILE"
	echo ""
	echo "Archived $archived completed plans to $ARCHIVE_FILE"
}

cmd_remove() {
	if [ ! -f "$PLANS_FILE" ]; then
		echo "ERROR: $PLANS_FILE not found" >&2
		exit 1
	fi

	local removed=0
	local temp_file
	temp_file=$(mktemp)
	cp "$PLANS_FILE" "$temp_file"

	while IFS= read -r header_line; do
		local line_num
		line_num=$(echo "$header_line" | cut -d: -f1)
		local status
		status=$(check_plan_completed "$line_num")

		if [ "$status" = "completed" ] || [ "$status" = "all_todos_done" ]; then
			local title
			title=$(echo "$header_line" | cut -d: -f2- | sed 's/^### //')

			local next_header
			next_header=$(tail -n +$((line_num + 1)) "$temp_file" | grep -n "^### \[" | head -1 | cut -d: -f1)
			if [ -n "$next_header" ]; then
				local end_line=$((line_num + next_header - 1))
			else
				local end_line
				end_line=$(wc -l < "$temp_file")
			fi

			sed -i "${line_num},${end_line}d" "$temp_file" 2>/dev/null || true
			removed=$((removed + 1))
			echo "Removed: $title"
		fi
	done < <(get_plan_sections)

	mv "$temp_file" "$PLANS_FILE"
	echo ""
	echo "Removed $removed completed plans"
}

cmd_status() {
	if [ ! -f "$PLANS_FILE" ]; then
		echo "ERROR: $PLANS_FILE not found" >&2
		exit 1
	fi

	local total=0
	local completed=0

	while IFS= read -r header_line; do
		local line_num
		line_num=$(echo "$header_line" | cut -d: -f1)
		local status
		status=$(check_plan_completed "$line_num")
		total=$((total + 1))

		if [ "$status" = "completed" ] || [ "$status" = "all_todos_done" ]; then
			completed=$((completed + 1))
		fi
	done < <(get_plan_sections)

	echo "{\"total\": $total, \"completed\": $completed, \"active\": $((total - completed))}"
}

command="${1:-help}"
shift || true

case "$command" in
	check)
		cmd_check
		;;
	archive)
		cmd_archive
		;;
	remove)
		cmd_remove
		;;
	status)
		cmd_status
		;;
	help|--help|-h)
		cat <<USAGE
Plans Cleanup Helper — Archive completed plans from PLANS.md

Usage:
  plans-cleanup-helper.sh check      Show which plans are completed
  plans-cleanup-helper.sh archive    Move completed plans to PLANS-ARCHIVE.md
  plans-cleanup-helper.sh remove     Remove completed plans entirely
  plans-cleanup-helper.sh status     Show JSON completion summary

Environment:
  PLANS_FILE    Path to PLANS.md (default: todo/PLANS.md)
  TODO_FILE     Path to TODO.md (default: TODO.md)
  ARCHIVE_FILE  Path to archive (default: todo/PLANS-ARCHIVE.md)
USAGE
		;;
	*)
		echo "Unknown command: $command" >&2
		echo "Run: plans-cleanup-helper.sh help" >&2
		exit 2
		;;
esac
