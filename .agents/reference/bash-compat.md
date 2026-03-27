# Bash 3.2 Compatibility (macOS default shell)

macOS ships bash 3.2.57. All shell scripts MUST work on this version.
Bash 4.0+ features silently crash or produce wrong results on 3.2 — no
error message, just broken behaviour. This has caused repeated production
failures (pulse dispatch, worktree cleanup, dataset helpers, routine scheduler).

## Forbidden features (bash 4.0+)

- `declare -A` / `local -A` (associative arrays) — use parallel indexed arrays or grep-based lookup
- `mapfile` / `readarray` — use `while IFS= read -r line; do arr+=("$line"); done < <(cmd)`
- `${var,,}` / `${var^^}` (case conversion) — use `tr '[:upper:]' '[:lower:]'` or `tr '[:lower:]' '[:upper:]'`
- `${var:offset:length}` negative offsets — use `${var: -N}` (space before minus) or string manipulation
- `|&` (pipe stderr) — use `2>&1 |`
- `&>>` (append both) — use `>> file 2>&1`
- `declare -n` / `local -n` (namerefs) — use eval or indirect expansion `${!var}`
- `[[ $var =~ regex ]]` with stored regex in variables works differently — test on 3.2

## Subshell and command substitution traps

- `$()` captures ALL stdout — never mix `tee` or command output with exit code capture in `$()`. Write exit codes to a temp file instead: `printf '%s' "$?" > "$exit_code_file"`
- `local -a arr=()` inside `$()` subshells — `local` in a subshell not inside a function is undefined in 3.2
- `PIPESTATUS` — available in 3.2 but only for the immediately preceding pipeline in the current shell. Inside `$()` it reflects the subshell's pipeline, not the parent's. Capture it immediately: `cmd1 | cmd2; local ps=("${PIPESTATUS[@]}")`

## Array passing across process boundaries

- Arrays cannot cross subshell, `$()`, or pipe boundaries as arrays. They flatten to strings.
- To pass an array to a subprocess: pass elements as separate positional arguments (`"${arr[@]}"`), never as a single escaped string (`printf -v str '%q ' "${arr[@]}"` then `"$str"` — the subprocess receives one argument, not many)
- To receive array results from a subprocess: write to a temp file (one element per line), then read back with `while read` loop

## Escape sequence quoting (recurring production-breaking bug)

Bash double quotes do NOT interpret `\t` `\n` `\r` as whitespace. They are literal
two-character sequences (backslash + letter). This is unlike C, Python, JS,
and most other languages. Agents repeatedly write `"\t"` expecting a tab —
this produces broken XML/plist/JSON/YAML and is invisible until runtime.

- `"\t"` → literal backslash-t (TWO characters). Use `$'\t'` for actual tab.
- `"\n"` → literal backslash-n (TWO characters). Use `$'\n'` for actual newline.
- For string concatenation with variables: `var+=$'\t'"${value}"` (ANSI-C quote for the tab, then double-quote for the variable expansion)
- Inside heredocs (`<<EOF`), tabs are literal tab characters (typed or pasted) — `\t` is NOT interpreted. This is correct and safe.
- `echo -e "\t"` interprets escapes but is non-portable. Prefer `printf '\t'`.
- `printf '%s\t%s' "$a" "$b"` is the safest portable way to embed tabs.
- When building XML/plist/JSON via string concatenation, ALWAYS use `$'\t'` for indentation — never `"\t"`. A single `"\t"` in a plist makes it unparseable and silently kills launchd jobs.

## zsh IFS=$'\t' + $() command substitution trap

The MCP Bash tool runs zsh on macOS. ROOT CAUSE: In zsh, lowercase `path` is a SPECIAL TIED ARRAY linked to PATH.
When `while IFS=$'\t' read -r size path` assigns `path=test.md`, it sets
PATH=test.md — destroying the PATH and making ALL external commands fail with
"command not found". This is NOT an IFS leak — it's a variable name collision.
Bash does not have this tied-array behaviour; zsh does.
This affects ALL inline shell commands generated for the MCP Bash tool (which uses
the user's default shell, typically zsh on macOS), even when the logic is correct bash.
Framework scripts with `#!/bin/bash` shebangs are safe when invoked directly.

NEVER use `path` as a loop variable in while-read loops (zsh tied array):

```bash
# WRONG — PATH=test.md, sed not found
echo -e "100\ttest.md" | while IFS=$'\t' read -r size path; do
  base=$(echo "$path" | sed 's|\.md$||')
done
```

SAFE alternatives:

```bash
# Option 1: rename the variable (avoid 'path', 'log', 'cdpath' — all zsh tied arrays)
while IFS=$'\t' read -r size file_path; do
  base="${file_path##*/}"      # parameter expansion — no subshell needed
  base="${base%.md}"
done

# Option 2: avoid IFS=$'\t' on the while line — parse with parameter expansion
while read -r line; do
  size="${line%%$'\t'*}"
  file_path="${line#*$'\t'}"
done

# Option 3: IFS save/restore before $() calls (defensive — use when renaming isn't feasible)
while IFS=$'\t' read -r size file_path; do
  local _saved_ifs="$IFS"
  IFS=$' \t\n'
  result=$(some_command "$file_path")
  IFS="$_saved_ifs"
done
# NOTE: IFS save/restore does NOT fix the 'path' tied-array issue — PATH is already
# clobbered when 'path' is assigned. Always rename 'path' to 'file_path' or similar.
```

zsh tied arrays to NEVER use as variable names in while-read loops:
`path` (→ PATH), `manpath` (→ MANPATH), `cdpath` (→ CDPATH), `fpath` (→ FPATH),
`mailpath` (→ MAILPATH), `module_path` (→ MODULE_PATH)

For framework `.sh` scripts (invoked directly, not inlined): already safe due to
`#!/bin/bash` shebangs. No change needed. The risk is inline agent-generated code only.

## Safe patterns

- Test scripts with `/bin/bash` (not `/opt/homebrew/bin/bash`) to catch 4.0+ usage
- When in doubt, check: `bash --version` on macOS gives 3.2.57
- ShellCheck does NOT catch most bash version incompatibilities — manual review required
- ShellCheck does NOT catch `"\t"` vs `$'\t'` — both are valid bash, just different semantics
- ShellCheck does NOT catch the zsh IFS leak — it only lints bash syntax, not zsh runtime behaviour
