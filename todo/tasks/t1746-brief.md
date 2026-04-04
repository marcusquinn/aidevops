<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1746: Standalone Research Repo Init — /autoresearch init

## Origin

- **Created:** 2026-04-01
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) + AI (interactive)
- **Parent task:** t1741
- **Conversation context:** User identified that standalone research repos (for topics without existing code) should get `aidevops init` applied so they benefit from task management, git workflow, memory, and pulse visibility. Unmanaged research repos are invisible to cross-repo tools.

## What

Implement the `/autoresearch init "name"` subcommand that scaffolds a new research repository with full aidevops integration.

The command creates:
1. `~/Git/autoresearch-{name}/` directory
2. `git init` inside it
3. `aidevops init` for task management
4. Registration in `~/.config/aidevops/repos.json`
5. Research-specific scaffold (program.md, baseline/, results tracking)
6. Optional: immediately begin the experiment loop

## Why

Some research topics don't have an existing codebase — ML model training, algorithm comparison, prompt engineering, data analysis experiments. These need a repo to live in, and that repo should be a first-class citizen in the aidevops ecosystem (task tracking, memory, pulse dispatch, cross-session learning). Without `aidevops init`, the research repo is orphaned and loses most of the value.

## How (Approach)

### Scaffold structure

```
~/Git/autoresearch-{name}/
├── program.md              # research instructions (human edits this)
├── baseline/               # starting code, data prep, config
│   └── .gitkeep
├── results/                # experiment results (optional: gitignored)
│   └── .gitkeep
├── TODO.md                 # from aidevops init
├── todo/
│   └── research/
│       └── {name}.md       # research program file (from t1742 template)
└── .aidevops.json          # from aidevops init
```

### repos.json registration

```json
{
  "path": "~/Git/autoresearch-{name}",
  "slug": "marcusquinn/autoresearch-{name}",
  "pulse": false,
  "local_only": true,
  "priority": "research",
  "app_type": "generic"
}
```

Default `pulse: false` and `local_only: true` because:
- Research repos may not need a GitHub remote initially
- Pulse dispatch to a research repo should be opt-in (user enables when ready)

The user can later:
- `gh repo create autoresearch-{name} --private` and set `local_only: false`
- Set `pulse: true` with `pulse_hours` for overnight runs

### Interactive prompts during init

```
/autoresearch init "llm-tokenizer-comparison"

Creating research repo: ~/Git/autoresearch-llm-tokenizer-comparison/

1. Description? (for README)
   → "Compare BPE, WordPiece, and Unigram tokenizers on domain-specific corpora"

2. Create GitHub remote? [y/N]
   → N (local only for now)

3. Enable pulse dispatch? [y/N]
   → N (manual runs for now)

4. Begin experiment loop now? [y/N]
   → Runs interactive setup from t1743 if Y

Repo created. Run `/autoresearch --repo ~/Git/autoresearch-llm-tokenizer-comparison/` to start.
```

### Naming convention

Prefix `autoresearch-` is mandatory for discoverability:
- `ls ~/Git/autoresearch-*` finds all research repos
- `grep autoresearch ~/.config/aidevops/repos.json` finds all registered ones
- Consistent with worktree naming: `~/Git/{repo}.experiment-{name}/`

## Acceptance Criteria

- [ ] `/autoresearch init "name"` creates `~/Git/autoresearch-{name}/` with git init
  ```yaml
  verify:
    method: codebase
    pattern: "autoresearch-.*git init|mkdir.*autoresearch"
    path: ".agents/scripts/commands/autoresearch.md"
  ```
- [ ] `aidevops init` is applied to the new repo
  ```yaml
  verify:
    method: codebase
    pattern: "aidevops init"
    path: ".agents/scripts/commands/autoresearch.md"
  ```
- [ ] Repo registered in repos.json with `local_only: true` default
  ```yaml
  verify:
    method: codebase
    pattern: "repos.json|local_only"
    path: ".agents/scripts/commands/autoresearch.md"
  ```
- [ ] Scaffold includes program.md, baseline/, results/, TODO.md
- [ ] Naming uses `autoresearch-` prefix
- [ ] Optional GitHub remote creation offered
- [ ] Optional pulse dispatch configuration offered
- [ ] Lint clean

## Context & Decisions

- `local_only: true` by default: most research repos start as local experiments. Pushing to GitHub should be opt-in when the user wants to share or archive.
- `pulse: false` by default: autonomous pulse dispatch to a research repo that isn't ready could waste tokens on a half-configured experiment. User enables when they've set up the program.
- `autoresearch-` prefix over a shared `/research` directory: separate repos are more flexible than subdirectories. Each can have its own git history, branches, and lifecycle. The prefix makes them easy to find while keeping them independent.

## Relevant Files

- `.agents/scripts/commands/autoresearch.md` — parent command doc (t1743)
- `setup.sh` — `aidevops init` implementation reference
- `~/.config/aidevops/repos.json` — registration target

## Dependencies

- **Blocked by:** t1743 (init is a subcommand of /autoresearch)
- **Blocks:** nothing

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Review aidevops init, repos.json format |
| Scaffold design | 30m | Directory structure, template files |
| Integration | 40m | repos.json registration, git init |
| Interactive prompts | 30m | Questions, defaults |
| **Total** | **~2h** | |
