<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Shell Portability: bash version + command coreutils

Two independent compatibility axes, both required:

1. **Bash version** — macOS ships bash 3.2.57; Linux ships bash 4.0+. Scripts must run on the LOWEST version (3.2).
2. **Command coreutils** — macOS ships BSD coreutils (no `getent`, `stat --format`, `readlink -f`, `date -d`, `timeout`); has `dscl`, `sw_vers`, `launchctl`, `pbcopy`. Linux ships GNU coreutils with the inverse. Scripts must run on BOTH.

Regression pattern: a fix for one axis breaks the other. Recent production failures:

- **t2074 (GH#18784)** — #18686 added `getent passwd` to `aidevops.sh` to fix Linux-sudo home resolution, omitted the `command -v getent` guard that `approval-helper.sh:33` had. Broke `sudo aidevops approve` on macOS with `getent: command not found` for a full release cycle.
- **GH#18770** — #18712 refactored `pulse-wrapper.sh` to fix one bash 3.2 issue but forgot `set -e` exit propagation from a `local var=$(f)` capture. Killed the pulse on Linux silently (launchd kept relaunching).
- **t1983 (GH#18423)** — GNU-awk-specific dynamic-regex construct silently broke `add_gh_ref_to_todo` on macOS BSD awk for weeks.
- **#17944** — `stat` argument order was Linux-first across 6 scripts; macOS BSD `stat` ignored them.

**Test both platforms before merging.** ShellCheck catches neither axis — manual review and regression tests required.

## Bash 3.2 Compatibility (macOS default shell)

macOS ships bash 3.2.57. All shell scripts MUST work on this version.
Bash 4.0+ features silently crash or produce wrong results — no error message.
Production failures: pulse dispatch, worktree cleanup, dataset helpers, routine scheduler.

## Forbidden features (bash 4.0+)

- `declare -A` / `local -A` — use parallel indexed arrays or grep-based lookup
- `mapfile` / `readarray` — use `while IFS= read -r line; do arr+=("$line"); done < <(cmd)`
- `${var,,}` / `${var^^}` (case conversion) — use `tr '[:upper:]' '[:lower:]'`
- `${var:offset:length}` negative offsets — use `${var: -N}` (space before minus)
- `|&` (pipe stderr) — use `2>&1 |`; `&>>` (append both) — use `>> file 2>&1`
- `declare -n` / `local -n` (namerefs) — use eval or indirect expansion `${!var}`
- `[[ $var =~ regex ]]` with stored regex — behaviour differs on 3.2, test explicitly

## Subshell and command substitution traps

- `$()` captures ALL stdout — never mix `tee` or command output with exit code capture. Write exit codes to a temp file: `printf '%s' "$?" > "$exit_code_file"`
- `local -a arr=()` inside `$()` — `local` in a subshell not inside a function is undefined in 3.2
- `PIPESTATUS` — available in 3.2 but only for the immediately preceding pipeline. Capture immediately: `cmd1 | cmd2; local ps=("${PIPESTATUS[@]}")`

## Array passing across process boundaries

Arrays flatten to strings across subshell, `$()`, or pipe boundaries. Pass via `${arr[@]+"${arr[@]}"}` (positional args, safe under `set -u`) or temp file (one element per line, read back with `while IFS= read -r`).

## Escape sequence quoting (recurring production bug)

Bash double quotes do NOT interpret `\t` `\n` `\r` — literal two-character sequences. A single `"\t"` in a plist makes it unparseable and silently kills launchd jobs.

| Wrong | Correct | Notes |
|-------|---------|-------|
| `"\t"` | `$'\t'` | ANSI-C quoting for actual tab |
| `"\n"` | `$'\n'` | ANSI-C quoting for actual newline |
| `echo -e "\t"` | `printf '\t'` | `echo -e` is non-portable |
| `"${var}\t"` | `$'\t'"${var}"` | Concatenate ANSI-C quote + double-quote |

Inside heredocs (`<<EOF`), tabs are literal — `\t` is NOT interpreted. `printf '%s\t%s' "$a" "$b"` is the safest portable form.

## zsh IFS + `$()` trap (MCP Bash tool)

The MCP Bash tool runs zsh on macOS. In zsh, `path` is a SPECIAL TIED ARRAY linked to `PATH`.
`while IFS=$'\t' read -r size path` assigns `path=test.md` → sets `PATH=test.md` → ALL external commands fail. Variable name collision, not an IFS leak. Framework scripts with `#!/bin/bash` shebangs are safe; risk is inline agent-generated code only.

```bash
# WRONG — PATH=test.md, sed not found
echo -e "100\ttest.md" | while IFS=$'\t' read -r size path; do
  base=$(echo "$path" | sed 's|\.md$||')
done

# SAFE — rename variable; use parameter expansion instead of subshell
while IFS=$'\t' read -r size file_path; do
  base="${file_path%.md}"
done
```

zsh tied arrays — NEVER use as loop variables:
`path` (PATH), `manpath` (MANPATH), `cdpath` (CDPATH), `fpath` (FPATH), `mailpath` (MAILPATH), `module_path` (MODULE_PATH)

## Safe patterns

- Test with `/bin/bash` (not `/opt/homebrew/bin/bash`) to catch 4.0+ usage
- ShellCheck does NOT catch: bash version incompatibilities, `"\t"` vs `$'\t'`, zsh tied-array collisions — manual review required

---

## Cross-platform command portability (GNU ↔ BSD ↔ macOS)

Even with a compatible bash version, external commands diverge silently between Linux (GNU coreutils) and macOS (BSD coreutils). The runtime error is usually `command not found` or subtly wrong output — never a lint warning.

**Rule:** any command that is NOT in the intersection of GNU + BSD coreutils MUST be either (a) guarded by `command -v <cmd> &>/dev/null`, (b) branched on `[[ "$(uname)" == "Darwin" ]]`, or (c) wrapped in a canonical portable helper. Never call such commands unconditionally.

### Linux-only commands (crash on macOS without guard)

| Command | macOS alternative | Canonical portable pattern |
|---------|-------------------|----------------------------|
| `getent passwd $user` | `dscl . -read /Users/$user NFSHomeDirectory` | `setup-modules/shell-env.sh:33-38` (dscl-first, getent-fallback, $HOME-fallback) |
| `readlink -f <path>` | `perl -MCwd -e 'print Cwd::realpath($ARGV[0])' "$path"` or loop | Prefer `cd "$(dirname "$f")" && pwd -P` when practical |
| `stat --format='%Y' <f>` | `stat -f '%m' <f>` | Probe order must be **Linux-first** (GNU `stat --format` fails fast on BSD, allowing the fallback branch). See #17944. |
| `date -d '1 hour ago'` | `date -v-1H` | Python one-liner is the most portable: `python3 -c 'import datetime; print((datetime.datetime.now()-datetime.timedelta(hours=1)).isoformat())'` |
| `timeout <secs> <cmd>` | coreutils `gtimeout` if installed, else `perl -e 'alarm shift; exec @ARGV' <secs> <cmd>` | `aidevops.sh:_timeout_cmd()` |
| `sed -i '...'` (GNU) | `sed -i '' '...'` (BSD requires empty suffix) | `aidevops.sh:sed_inplace()` — `if Darwin; sed -i ''; else sed -i; fi` |
| `sed -r '...'` (extended regex) | `sed -E '...'` | `sed -E` works on both — always use `-E`, never `-r`. |
| `grep -P '...'` (PCRE) | N/A on BSD grep | Use `grep -E` with POSIX ERE, or pipe to `perl -ne '...'`. |
| `awk` dynamic regex `match($0, var)` | BSD awk rejects non-literal regex | Use `gsub()` with literal patterns, or switch to `perl`. Caught production bug t1983. |
| `xargs -r` | BSD xargs has no `-r`; empty input is a no-op by default | Pre-check input with `[[ -s input ]]` before calling xargs, or use `find ... -exec {} +` which is portable. |
| `find -printf` | BSD find has no `-printf` | Use `find ... -exec <fmt-cmd> {} +` or pipe through `stat`. |
| `mktemp --suffix=.X` | BSD mktemp uses `-t prefix` differently | `mktemp -t aidevops.XXXXXX` works on both; never use `--suffix`. |
| `sha256sum <f>` | `shasum -a 256 <f>` | `shasum -a 256` is POSIX-compliant and available on both. |
| `base64 -w 0` | BSD `base64` has no `-w`; output is already one line | `base64 \| tr -d '\n'` portable. |
| `readelf`, `ldd`, `strace`, `lsof` flags | Different or missing | Not typically used in aidevops scripts; document if needed. |

### macOS-only commands (crash on Linux without guard)

| Command | Linux alternative | When used |
|---------|-------------------|-----------|
| `dscl . -read /Users/$u NFSHomeDirectory` | `getent passwd $u \| cut -d: -f6` | User home/shell lookup |
| `sw_vers -productVersion` | `lsb_release -rs` or `/etc/os-release` | OS version detection |
| `launchctl` | `systemctl` | Scheduler/service management |
| `pbcopy` / `pbpaste` | `xclip -selection clipboard` or `wl-copy` | Clipboard I/O |
| `sysctl -n hw.ncpu` | `nproc` or `sysctl -n kernel.ncpu` | CPU count (portable: `getconf _NPROCESSORS_ONLN`) |
| `defaults read/write` | N/A | macOS plist — always guard with `[[ "$(uname)" == "Darwin" ]]` |
| `security find-generic-password` | `secret-tool` or gopass | Keychain access |
| `codesign`, `xcrun`, `hdiutil` | N/A | macOS-only toolchain |

### Canonical portable wrappers (already in-tree)

Prefer these over inlining a conditional each time:

| Wrapper | Location | Purpose |
|---------|----------|---------|
| `sed_inplace` | `aidevops.sh:39` | In-place sed edit, BSD/GNU |
| `_timeout_cmd` | `aidevops.sh:42-55` | Timeout command with perl fallback |
| `_resolve_real_home()` | `.agents/scripts/approval-helper.sh:32-39` | SUDO_USER home resolution, dscl/getent/`$HOME` |
| `detect_default_shell()` | `setup-modules/shell-env.sh:28-45` | Login shell, dscl/getent/$SHELL |

When adding a new portable wrapper, document it in this table and ShellCheck-clean it.

### Pre-merge checklist for scripts that touch external commands

Before merging any shell script PR that touches coreutils, answer these:

1. Does the script call any command in the Linux-only or macOS-only tables above? If yes, is it guarded?
2. Does the CI matrix exercise both macOS + Linux for this script? (`bash-32-scanner` job in `.github/workflows/` + a manual macOS run.)
3. Is there a regression test that runs under the MISSING platform's conditions? (e.g., `test-aidevops-sh-portability.sh` strips `getent` off PATH to simulate macOS.)
4. Has the change been reviewed for `set -e` exit-code propagation through `local var=$(f)` captures? (GH#18770 cautionary tale.)

Failing any of these is a P0 regression risk — the bug will only surface on the unreviewed platform, often days after merge when the pulse or approval flow breaks silently.
