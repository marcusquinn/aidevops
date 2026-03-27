---
description: ComfyUI management via comfy-cli — install, launch, nodes, models, workflows
mode: subagent
model: sonnet
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: false
---

# @comfy-cli - ComfyUI Automation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `comfy-cli-helper.sh [command]` (wraps comfy-cli with aidevops conventions)
- **Install**: `pip install comfy-cli` or `brew install comfy-org/comfy-cli/comfy-cli`
- **Docs**: <https://docs.comfy.org/comfy-cli/getting-started>
- **Repo**: <https://github.com/Comfy-Org/comfy-cli>
- **Prerequisites**: Python >= 3.9, git, CUDA or ROCm (GPU)

<!-- AI-CONTEXT-END -->

## Installation

```bash
pip install comfy-cli              # or: brew install comfy-org/comfy-cli/comfy-cli
comfy --install-completion         # shell completion

# Install ComfyUI (use a venv)
conda create -n comfy-env python=3.11 && conda activate comfy-env
comfy install
```

## Commands

### Core

| Command | Description |
|---------|-------------|
| `comfy install` | Install ComfyUI into current environment |
| `comfy launch` | Start ComfyUI server |
| `comfy launch -- --listen 0.0.0.0 --port 8188` | Launch with custom flags |

### Nodes (`comfy node`)

| Command | Description |
|---------|-------------|
| `comfy node install/uninstall/update/reinstall <name>` | Manage a custom node |
| `comfy node enable/disable <name>` | Toggle without removing |
| `comfy node show <filter>` | List nodes — filters: `installed`, `enabled`, `disabled`, `not-installed`, `all`, `snapshot`, `snapshot-list` |
| `comfy node fix <name>` | Fix dependencies for a node |
| `comfy node install-deps [--workflow f.json] [--deps d.json]` | Install deps from workflow or spec file |
| `comfy node deps-in-workflow --workflow f.json --output d.json` | Extract workflow deps to file |
| `comfy node save-snapshot [--output snap.json]` | Save environment snapshot |
| `comfy node restore-snapshot <path>` | Restore from snapshot |
| `comfy node restore-dependencies` | Restore all node dependencies |

All node subcommands accept `--channel TEXT` (operation mode) and `--mode TEXT` (`remote`, `local`, `cache`).

### Models (`comfy model`)

| Command | Description |
|---------|-------------|
| `comfy model download --url <url> [--relative-path models/loras]` | Download model (optionally to specific folder) |
| `comfy model list [--relative-path models/loras]` | List downloaded models |
| `comfy model remove --model-names "model.safetensors"` | Remove a model |

`comfy tracking disable/enable` — toggle usage analytics.

## Helper Script

`comfy-cli-helper.sh` wraps comfy-cli with aidevops conventions. Commands map directly:

```bash
comfy-cli-helper.sh status                              # Check if comfy-cli is installed
comfy-cli-helper.sh install                             # Install comfy-cli
comfy-cli-helper.sh setup [--path /path/to/comfyui]     # Install ComfyUI
comfy-cli-helper.sh launch [--port 8188] [--listen 0.0.0.0]
comfy-cli-helper.sh node-install <name>
comfy-cli-helper.sh node-list [installed|all|enabled|disabled]
comfy-cli-helper.sh model-download <url> [relative-path]
comfy-cli-helper.sh model-list [relative-path]
comfy-cli-helper.sh snapshot-save [--output file.json]
comfy-cli-helper.sh snapshot-restore <file.json>
comfy-cli-helper.sh workflow-deps <workflow.json>
```

## Common Workflows

```bash
# Reproduce a workflow from a .json file
comfy-cli-helper.sh workflow-deps workflow.json
comfy-cli-helper.sh model-download "https://civitai.com/api/download/models/12345" models/checkpoints
comfy-cli-helper.sh launch

# Environment backup/restore
comfy-cli-helper.sh snapshot-save --output my-setup.json
comfy-cli-helper.sh snapshot-restore my-setup.json       # on another machine
```

## Related

- `content/production/image.md`, `content/production/video.md` — local ComfyUI-based generation pipelines
- `tools/vision/overview.md` — Vision AI decision tree
- `tools/vision/image-generation.md` — local model inference
- `tools/video/higgsfield.md` — cloud-based AI generation
