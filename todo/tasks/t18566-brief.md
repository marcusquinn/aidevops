# t18566: chore: retire DSPy and DSPyGround from setup, docs and status checks

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33141
- **Conversation context:** Framework value audit (parent GH#33139); maintainer approved retiring redundant tooling while keeping the useful ideas.

## Why

DSPy and DSPyGround have no framework workflow that depends on them, yet setup installs them and status checks report on them. That costs install time and maintenance for unused prompt-optimisation tooling.

## What

Remove DSPy and DSPyGround. Parent: GH#33139.

Setup still builds a Python venv and globally installs the `dspyground` npm package (`.agents/scripts/setup/modules/tool-install-environments.sh:131-213`), but nothing in the framework uses them. The maintainer decided that clear aidevops guidance, plus the model-replay and agent-test evaluation paths, covers the goal DSPy served: less variance in how prompts are interpreted.

## How

- Stop setup installing DSPy and DSPyGround. Remove the venv, DSPy cache hardening, and `dspyground` install blocks from `tool-install-environments.sh`, and the DSPy cache pre-step at `setup.sh:161-170`.
- Delete `dspy-helper.sh`, `dspyground-helper.sh`, `dspy-cache-security.sh` and its test, the two config templates, and the docs `tools/context/dspy.md`, `dspyground.md` and `prompt-optimization.md`.
- Remove DSPy from `requirements.txt` and `requirements-lock.txt`, and remove the `dspy:*` and `install:python` scripts and the `dspy` keyword from `package.json`. If `requirements.txt` then has no other packages, remove the file and every reference to it.
- Remove the status, version-check and auto-update entries: `aidevops-status-lib.sh`, `tool-version-check.sh`, `auto-update-helper.sh`, `auto-update-helper-status.sh`, and their tests.
- Add a one-time migration in `.agents/scripts/setup/modules/migrations.sh` that:
  - removes the aidevops-owned `python-env/dspy-env` venv and any persisted DSPy cache env line;
  - removes the deployed docs and helpers;
  - prints a one-line advisory with the `npm uninstall -g dspyground` command when `dspyground` is on PATH. Do not uninstall global packages automatically, because the user may use them independently.
- Update the doc mentions in `environment-variables.md`, `ai-orchestration/openprose.md`, `overview.md` and `service-links.md`.
- Leave `.agents/advisories/litellm-2026-03.advisory` unchanged; it is a historical record.

## Reference pattern

Model the migration on `cleanup_osgrep()` in `.agents/scripts/setup/modules/migrations.sh:272-360`: guarded removal, one success line, idempotent.

### Files Scope

- `setup.sh`
- `requirements.txt`
- `requirements-lock.txt`
- `package.json`
- `configs/dspy-config.json.txt`
- `configs/dspyground-config.json.txt`
- `docs/sonar-exemptions.md`
- `.agents/tools/context/dspy.md`
- `.agents/tools/context/dspyground.md`
- `.agents/tools/context/prompt-optimization.md`
- `.agents/tools/credentials/environment-variables.md`
- `.agents/tools/ai-orchestration/openprose.md`
- `.agents/tools/ai-orchestration/overview.md`
- `.agents/aidevops/service-links.md`
- `.agents/configs/vault-requirements.txt`
- `.agents/configs/allowed-urls.txt`
- `.agents/configs/simplification-state.json`
- `.agents/subagent-index.toon`
- `.agents/scripts/dspy-helper.sh`
- `.agents/scripts/dspyground-helper.sh`
- `.agents/scripts/dspy-cache-security.sh`
- `.agents/scripts/tests/test-dspy-cache-security.sh`
- `.agents/scripts/setup/modules/tool-install-environments.sh`
- `.agents/scripts/setup/modules/post-setup.sh`
- `.agents/scripts/setup/modules/migrations.sh`
- `.agents/scripts/aidevops-cli/aidevops-status-lib.sh`
- `.agents/scripts/tool-version-check.sh`
- `.agents/scripts/tests/test-tool-version-check-opencode.sh`
- `.agents/scripts/tests/test-tool-version-check-classify.sh`
- `.agents/scripts/auto-update-helper.sh`
- `.agents/scripts/auto-update-helper-status.sh`

## Acceptance criteria

- [ ] A fresh `setup.sh --non-interactive` creates no DSPy venv and installs no `dspyground`.
- [ ] On an existing install, the migration removes the aidevops-owned venv and deployed files once, and prints the npm advisory only when `dspyground` is present.
- [ ] `rg -n -i dspy` outside CHANGELOG, advisories and the migration returns nothing.
- [ ] ShellCheck is clean for all touched scripts.

## Verification

```bash
rg -n -i dspy --glob '!CHANGELOG.md' --glob '!*.advisory' .
shellcheck setup.sh .agents/scripts/setup/modules/tool-install-environments.sh .agents/scripts/setup/modules/migrations.sh .agents/scripts/tool-version-check.sh
.agents/scripts/linters-local.sh
```

Parent: #33139
