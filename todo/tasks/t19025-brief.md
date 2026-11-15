<!-- aidevops:brief-schema=v2 -->

# t19025: fix(ci): stop the main-push shell portability scan failing with "Argument list too long"

## Origin

- **Created:** 2026-11-15
- **Created by:** ai-interactive (aidevops productivity mission, parent GH#38332)
- **Conversation context:** While verifying the v3.39.203 release, the Shell Portability Gate failed on every recent `main` push. Main-push runs are meant to be advisory only.

## What

On `main` pushes, `.github/workflows/shell-portability.yml` should run the advisory scan over all tracked `.sh` files without passing the file list through an environment variable.

## Why

The detect job builds the main-push list with `git ls-files '*.sh'`: 2,760 files, 135,800 bytes. The scan job receives it as the single `CHANGED_FILES` env value. Linux caps a single argv/env string at 131,072 bytes (`MAX_ARG_STRLEN`). The runner therefore cannot start bash:

```text
##[error]An error occurred trying to start process '/usr/bin/bash' ... Argument list too long
```

Runs 43696859369, 43695107271 and 43695007249 on `main` all failed this way. The scan never ran, and a red check on `main` is noise for review and repair automation.

## Tier

**Selected tier:** `tier:simple`

**Tier rationale:** One workflow file. `lint-shell-portability.sh` already scans all tracked `.sh` files when given no arguments.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/shell-portability.yml` — on a push, the detect job emits `scan_all=true` and no file list. The scan step runs `lint-shell-portability.sh` with no arguments when `SCAN_ALL` is `true`. The PR path is unchanged and still scans only the changed files.

### Verification

```bash
actionlint .github/workflows/shell-portability.yml   # when available
bash .agents/scripts/lint-shell-portability.sh --summary --no-exit-code   # local no-arg mode
# After merge: the next main-push Shell Portability Gate run completes (advisory success).
```

### Files Scope

- `.github/workflows/shell-portability.yml`
- `TODO.md`

## Acceptance Criteria

- [ ] Main-push runs no longer put the full file list in an environment variable.
- [ ] PR runs still scan only the changed `.sh` files and still block on violations.
- [ ] The next `main` push run of Shell Portability Gate succeeds.
