# t1909: Add install-systemd subcommand to routine-helper.sh

## Origin

- **Created:** 2026-04-07
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (prompted by review of GH#17692)
- **Conversation context:** During review of GH#17692, the issue was validated as a real gap — `routine-helper.sh` has `install-cron` and `install-launchd` but no `install-systemd`. The reporter's analysis was accurate. Brief written to make the task `tier:simple` dispatchable with verbatim code blocks.

## What

Add `cmd_install_systemd()` function and `install-systemd` case to `routine-helper.sh`, plus a platform-auto-detecting `install` subcommand. On Linux with `AIDEVOPS_SCHEDULER=systemd`, users get systemd timer installation with `Persistent=true` catch-up, journal logging, and concurrent-run prevention.

## Why

`routine-helper.sh` predates the t1748 Linux platform work. When GH#17447 centralised systemd in `setup-modules/schedulers.sh`, the user-facing `routine-helper.sh` was not updated. On Linux, users currently have no path to install scheduled routines via systemd. The framework already detects and exports `AIDEVOPS_SCHEDULER=systemd` via `platform-detect.sh`, but `routine-helper.sh` ignores it.

## Tier

`tier:simple`

**Tier rationale:** Single-file edit with exact code blocks provided below. The pattern is established in both `cmd_install_cron()` (routine-helper.sh:289-317) and `_install_scheduler_systemd()` (schedulers.sh:488-560). This brief provides complete, copy-pasteable function bodies.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/routine-helper.sh:16-42` — update `print_usage()` with new subcommands
- `EDIT: .agents/scripts/routine-helper.sh:387-414` — add `install-systemd` and `install` cases to `main()`
- `EDIT: .agents/scripts/routine-helper.sh:386` — insert `cmd_install_systemd()` and `parse_cron_to_oncalendar()` functions before `main()`

### Implementation Steps

1. **Add `parse_cron_to_oncalendar()` function** (insert after `parse_cron_to_launchd_xml()` at line ~188, before `parse_common_args()`):

```bash
# Convert 5-field cron expression to systemd OnCalendar spec.
# Only supports '*' or numeric values (same restriction as parse_cron_to_launchd_xml).
# Args: $1 = "minute hour day_of_month month weekday"
parse_cron_to_oncalendar() {
	local schedule="$1"
	local minute=""
	local hour=""
	local day_of_month=""
	local month=""
	local weekday=""

	read -r minute hour day_of_month month weekday <<<"$schedule"

	local value
	for value in "$minute" "$hour" "$day_of_month" "$month" "$weekday"; do
		if [[ "$value" != "*" && ! "$value" =~ ^[0-9]+$ ]]; then
			die "systemd install supports only '*' or numeric cron fields"
			return 1
		fi
	done

	# systemd OnCalendar format: DayOfWeek Year-Month-Day Hour:Minute:Second
	# cron weekday: 0=Sun,1=Mon..6=Sat,7=Sun; systemd: Mon,Tue,Wed,Thu,Fri,Sat,Sun
	local dow_map=("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun")
	local cal_dow="*"
	if [[ "$weekday" != "*" ]]; then
		cal_dow="${dow_map[$weekday]}"
	fi

	local cal_month="*"
	[[ "$month" != "*" ]] && cal_month=$(printf '%02d' "$month")

	local cal_day="*"
	[[ "$day_of_month" != "*" ]] && cal_day=$(printf '%02d' "$day_of_month")

	local cal_hour="*"
	[[ "$hour" != "*" ]] && cal_hour=$(printf '%02d' "$hour")

	local cal_min="00"
	[[ "$minute" != "*" ]] && cal_min=$(printf '%02d' "$minute")

	# Format: "DayOfWeek *-Month-Day Hour:Minute:00"
	printf '%s *-%s-%s %s:%s:00' "$cal_dow" "$cal_month" "$cal_day" "$cal_hour" "$cal_min"
	return 0
}
```

2. **Add `cmd_install_systemd()` function** (insert after `cmd_install_launchd()`, before `main()`):

```bash
cmd_install_systemd() {
	parse_common_args "$@" || {
		local rc=$?
		[[ $rc -eq 2 ]] && return 0
		return 1
	}

	local command
	command=$(build_opencode_command "$ROUTINE_DIR" "$ROUTINE_PROMPT" "$ROUTINE_AGENT" "$ROUTINE_TITLE" "$ROUTINE_MODEL")

	local on_calendar
	on_calendar=$(parse_cron_to_oncalendar "$ROUTINE_SCHEDULE") || return 1

	local service_name="sh.aidevops.routine-${ROUTINE_NAME}"
	local service_dir="$HOME/.config/systemd/user"
	local service_file="${service_dir}/${service_name}.service"
	local timer_file="${service_dir}/${service_name}.timer"
	local log_file="$HOME/.aidevops/logs/routine-${ROUTINE_NAME}.log"

	mkdir -p "$service_dir" "$HOME/.aidevops/logs"

	cat >"$service_file" <<EOF
[Unit]
Description=aidevops routine ${ROUTINE_NAME}
After=network.target

[Service]
Type=oneshot
KillMode=process
ExecStart=/bin/bash -lc $(printf '%q' "$command")
Environment=HOME=${HOME}
Environment=PATH=${PATH}
StandardOutput=append:${log_file}
StandardError=append:${log_file}
EOF

	cat >"$timer_file" <<EOF
[Unit]
Description=aidevops routine ${ROUTINE_NAME} Timer

[Timer]
OnCalendar=${on_calendar}
Persistent=true

[Install]
WantedBy=timers.target
EOF

	systemctl --user daemon-reload 2>/dev/null || true
	if systemctl --user enable --now "${service_name}.timer" 2>/dev/null; then
		printf '[OK] Installed systemd timer: %s\n' "$service_name"
		printf '[INFO] OnCalendar=%s (from cron: %s)\n' "$on_calendar" "$ROUTINE_SCHEDULE"
	else
		printf '[OK] Wrote systemd units: %s\n' "$service_file"
		printf '[INFO] OnCalendar=%s (from cron: %s)\n' "$on_calendar" "$ROUTINE_SCHEDULE"
		printf '[INFO] Enable with: systemctl --user enable --now %s.timer\n' "$service_name"
	fi
	return 0
}
```

3. **Add `install` auto-detect subcommand and `install-systemd` case** to `main()` (routine-helper.sh:392-414):

```bash
	case "$command" in
	plan)
		cmd_plan "$@"
		return $?
		;;
	install-cron)
		cmd_install_cron "$@"
		return $?
		;;
	install-launchd)
		cmd_install_launchd "$@"
		return $?
		;;
	install-systemd)
		cmd_install_systemd "$@"
		return $?
		;;
	install)
		# Auto-detect scheduler from platform-detect.sh
		source "${SCRIPT_DIR}/platform-detect.sh" 2>/dev/null || true
		case "${AIDEVOPS_SCHEDULER:-cron}" in
		launchd)   cmd_install_launchd "$@" ;;
		systemd)   cmd_install_systemd "$@" ;;
		*)         cmd_install_cron "$@" ;;
		esac
		return $?
		;;
	help | --help | -h)
		print_usage
		return 0
		;;
	*)
		die "Unknown command: $command"
		print_usage
		return 1
		;;
	esac
```

4. **Update `print_usage()`** — add `install-systemd` and `install` to the usage block (routine-helper.sh:16-42):

```bash
print_usage() {
	cat <<'EOF'
routine-helper.sh - Plan and install scheduled opencode routines

Usage:
  routine-helper.sh plan --name NAME --schedule "CRON" --dir PATH --prompt "..." [options]
  routine-helper.sh install --name NAME --schedule "CRON" --dir PATH --prompt "..." [options]
  routine-helper.sh install-launchd --name NAME --schedule "CRON" --dir PATH --prompt "..." [options]
  routine-helper.sh install-cron --name NAME --schedule "CRON" --dir PATH --prompt "..." [options]
  routine-helper.sh install-systemd --name NAME --schedule "CRON" --dir PATH --prompt "..." [options]

Subcommands:
  plan              Show what would be installed (dry run)
  install           Auto-detect scheduler (launchd/systemd/cron) and install
  install-launchd   Install as macOS launchd agent
  install-cron      Install as cron entry
  install-systemd   Install as systemd user timer (Linux)

Options:
  --name NAME       Routine name (used in labels/markers)
  --schedule CRON   Cron schedule expression (five fields)
  --dir PATH        Repository working directory for opencode run
  --prompt TEXT     Command/prompt to execute (non-code ops should NOT use /full-loop)
  --agent NAME      Agent name (default: Build+)
  --title TEXT      Session title (default: Scheduled routine)
  --model MODEL     Optional explicit model (default: runtime default)

Examples:
  routine-helper.sh install --name seo-weekly --schedule "0 9 * * 1" \
    --dir ~/Git/aidev-ops-client-seo-reports --agent SEO \
    --title "Weekly rankings" --prompt "/seo-export --account client-a --format summary"

  routine-helper.sh install-systemd --name seo-weekly --schedule "0 9 * * 1" \
    --dir ~/Git/aidev-ops-client-seo-reports --agent SEO \
    --title "Weekly rankings" --prompt "/seo-export --account client-a --format summary"
EOF
	return 0
}
```

### Verification

```bash
# ShellCheck must pass clean
shellcheck .agents/scripts/routine-helper.sh

# Verify new subcommands are registered
grep -c 'install-systemd\|cmd_install_systemd\|install)' .agents/scripts/routine-helper.sh
# Expected: at least 4 matches

# Verify parse_cron_to_oncalendar output
bash -c 'source .agents/scripts/routine-helper.sh; parse_cron_to_oncalendar "0 9 * * 1"'
# Expected: "Mon *-*-* 09:00:00"

# Verify usage shows all subcommands
.agents/scripts/routine-helper.sh --help | grep -c 'install'
# Expected: at least 6 lines
```

## Acceptance Criteria

- [ ] `routine-helper.sh install-systemd` writes `.service` and `.timer` files to `~/.config/systemd/user/`
  ```yaml
  verify:
    method: codebase
    pattern: "cmd_install_systemd"
    path: ".agents/scripts/routine-helper.sh"
  ```
- [ ] `routine-helper.sh install` auto-detects scheduler from `AIDEVOPS_SCHEDULER` and delegates
  ```yaml
  verify:
    method: codebase
    pattern: "AIDEVOPS_SCHEDULER"
    path: ".agents/scripts/routine-helper.sh"
  ```
- [ ] Cron expressions are converted to systemd OnCalendar format via `parse_cron_to_oncalendar()`
  ```yaml
  verify:
    method: codebase
    pattern: "parse_cron_to_oncalendar"
    path: ".agents/scripts/routine-helper.sh"
  ```
- [ ] Timer uses `Persistent=true` for catch-up execution after missed runs
  ```yaml
  verify:
    method: codebase
    pattern: "Persistent=true"
    path: ".agents/scripts/routine-helper.sh"
  ```
- [ ] `print_usage()` documents all five subcommands (plan, install, install-launchd, install-cron, install-systemd)
  ```yaml
  verify:
    method: bash
    run: "grep -c 'install' .agents/scripts/routine-helper.sh | awk '{exit ($1 >= 10 ? 0 : 1)}'"
  ```
- [ ] Naming convention `sh.aidevops.routine-{name}` matches launchd convention
  ```yaml
  verify:
    method: codebase
    pattern: "sh\\.aidevops\\.routine-"
    path: ".agents/scripts/routine-helper.sh"
  ```
- [ ] ShellCheck passes clean
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/routine-helper.sh"
  ```

## Context & Decisions

- **Pattern source**: `_install_scheduler_systemd()` in `setup-modules/schedulers.sh:488-560` is the authoritative systemd pattern. The routine-helper version is simplified because it doesn't need env var passthrough (handled by the login shell `-l` flag) or low-priority scheduling.
- **Cron-to-OnCalendar conversion**: New `parse_cron_to_oncalendar()` function mirrors `parse_cron_to_launchd_xml()` — same input validation (only `*` or numeric), parallel structure. This keeps the interface consistent: all `install-*` subcommands accept cron expressions.
- **Auto-detect `install` subcommand**: Sources `platform-detect.sh` to read `AIDEVOPS_SCHEDULER` and delegates to the right backend. This eliminates the need for users to know their scheduler.
- **`printf '%q'` for ExecStart**: Simplified escaping compared to `_systemd_escape()` in schedulers.sh. The `printf '%q'` approach is sufficient for the single-command case in routine-helper and avoids importing the helper function.

## Relevant Files

- `.agents/scripts/routine-helper.sh` — the file to edit (all changes here)
- `setup-modules/schedulers.sh:488-560` — reference pattern for systemd unit generation
- `.agents/scripts/platform-detect.sh:38-40` — where `AIDEVOPS_SCHEDULER=systemd` is exported

## Dependencies

- **Blocked by:** nothing
- **Blocks:** nothing (standalone enhancement)
- **External:** none (systemd is the target platform's init system)
- **Related:** GH#17691 (worker-watchdog.sh same class of gap — independent, not blocking)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 0m | Brief provides all code blocks |
| Implementation | 15m | Copy code blocks, adjust line positions |
| Testing | 5m | shellcheck + grep verification |
| **Total** | **~20m** | |
