# Bash 3.2 Compatibility (macOS default shell)

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

Arrays flatten to strings across subshell, `$()`, or pipe boundaries. Pass via `"${arr[@]}"` (positional args) or temp file (one element per line, read back with `while read`).

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
