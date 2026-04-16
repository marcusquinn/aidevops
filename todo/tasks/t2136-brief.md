# t2136: test: add integration tests for voice-bridge and normalise-markdown decomposition

## Origin

- **Created:** 2026-04-16
- **Session:** Claude Code (interactive)
- **Created by:** marcusquinn (human, interactive)
- **Parent task:** t2131 (decompose voice-bridge/normalise-markdown/tabby-profile-sync)
- **Conversation context:** PR #19238 (t2131) decomposed 3 Python scripts into helper modules. Review found that only `tabby-profile-sync.py` has a test (`tests/test-tabby-profile-sync.py`). The other two decomposed scripts — `voice-bridge.py` and `normalise-markdown.py` — lack test coverage for their refactored module boundaries.

## What

Add integration test files for `voice-bridge.py` and `normalise-markdown.py` that verify the decomposed module boundaries work correctly — matching the pattern and coverage level of the existing `tests/test-tabby-profile-sync.py`.

## Why

PR #19238 decomposed all three scripts but only verified tabby with a test. The voice-bridge and normalise-markdown decompositions are untested at the module boundary level. A future refactor could break imports or function signatures without any test catching it.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** (2 new test files)
- [x] **Every target file under 500 lines?** (new files, will be short)
- [ ] **Exact `oldString`/`newString` for every edit?** (new files, not edits — but needs judgment on what to test)
- [x] **No judgment or design decisions?** (follow existing pattern closely, but some judgment on what functions to exercise)
- [x] **No error handling or fallback logic to design?**
- [x] **No cross-package or cross-module changes?**
- [x] **Estimate 1h or less?**
- [x] **4 or fewer acceptance criteria?**

**Selected tier:** `tier:standard`

**Tier rationale:** New files following a clear pattern, but the worker needs to read the decomposed modules to decide which functions/imports to test. Not a mechanical copy-paste — requires understanding the module API surface.

## How (Approach)

### Files to Modify

- `NEW: tests/test-voice-bridge.py` — model on `tests/test-tabby-profile-sync.py`
- `NEW: tests/test-normalise-markdown.py` — model on `tests/test-tabby-profile-sync.py`

### Implementation Steps

1. **Create `tests/test-voice-bridge.py`** following the pattern in `tests/test-tabby-profile-sync.py`:
   - Use `importlib.util.spec_from_file_location` to import `voice-bridge.py` (hyphenated filename)
   - Import each helper module: `voice_bridge_cli`, `voice_stt`, `voice_tts`, `voice_llm`, `voice_bridge_core`
   - Test that the entry point module imports successfully under current Python
   - Test that key functions are callable from each helper module (e.g., `parse_args`, `run_bridge` from `voice_bridge_cli`)
   - Do NOT test actual audio/TTS/STT functionality (requires hardware) — only test import paths and function existence

   Reference pattern from `tests/test-tabby-profile-sync.py`:
   ```python
   spec = importlib.util.spec_from_file_location(
       "voice_bridge", SCRIPTS_DIR / "voice-bridge.py"
   )
   voice_bridge = importlib.util.module_from_spec(spec)
   spec.loader.exec_module(voice_bridge)
   ```

2. **Create `tests/test-normalise-markdown.py`** following the same pattern:
   - Import `normalise-markdown.py` via `importlib`
   - Import helpers: `normalise_markdown_headings`, `normalise_markdown_email`
   - Test that `normalise_heading_hierarchy` is callable from the headings module
   - Test that `detect_email_sections` is callable from the email module
   - Test a simple functional case: pass a list of lines through `normalise_heading_hierarchy` and verify output is a list
   - Test `align_table_pipes` (still in the main module) with a simple table

3. Run both test files to verify they pass.

### Verification

```bash
python3 tests/test-voice-bridge.py
python3 tests/test-normalise-markdown.py
```

## Acceptance Criteria

- [ ] `tests/test-voice-bridge.py` exists and passes (`python3 tests/test-voice-bridge.py`)
  ```yaml
  verify:
    method: bash
    run: "python3 tests/test-voice-bridge.py"
  ```
- [ ] `tests/test-normalise-markdown.py` exists and passes (`python3 tests/test-normalise-markdown.py`)
  ```yaml
  verify:
    method: bash
    run: "python3 tests/test-normalise-markdown.py"
  ```
- [ ] Both test files follow the `importlib.util.spec_from_file_location` pattern from `tests/test-tabby-profile-sync.py`
  ```yaml
  verify:
    method: codebase
    pattern: "spec_from_file_location"
    path: "tests/test-voice-bridge.py"
  ```

## Context & Decisions

- Follow the existing test pattern exactly — `importlib` dynamic import for hyphenated filenames, `unittest.TestCase` classes
- Voice-bridge tests must NOT attempt actual audio capture/playback — only verify module structure and import paths
- normalise-markdown tests can include a simple functional test (pass lines through a function) since no external deps are needed
- This is a follow-up to t2131 (PR #19238) which decomposed the scripts but only tested tabby

## Relevant Files

- `tests/test-tabby-profile-sync.py` — reference pattern to follow
- `.agents/scripts/voice-bridge.py` — entry point (thin wrapper)
- `.agents/scripts/voice_bridge_cli.py` — CLI helpers
- `.agents/scripts/voice_stt.py` — STT module
- `.agents/scripts/voice_tts.py` — TTS module
- `.agents/scripts/voice_llm.py` — LLM module
- `.agents/scripts/voice_bridge_core.py` — core loop
- `.agents/scripts/normalise-markdown.py` — entry point (table alignment + main)
- `.agents/scripts/normalise_markdown_headings.py` — heading helpers
- `.agents/scripts/normalise_markdown_email.py` — email section helpers

## Dependencies

- **Blocked by:** t2131 / PR #19238 must merge first (the decomposed modules must exist on main)
- **Blocks:** nothing
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Read existing test + 2 entry points |
| Implementation | 30m | Write 2 test files |
| Testing | 10m | Run tests, fix any import issues |
| **Total** | **~50m** | |
