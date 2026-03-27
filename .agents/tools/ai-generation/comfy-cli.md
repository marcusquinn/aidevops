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

- **CLI**: `comfy-cli-helper.sh [command]`
- **Install**: `pip install comfy-cli` or `brew install comfy-org/comfy-cli/comfy-cli`
- **Docs**: <https://docs.comfy.org/comfy-cli/getting-started>
- **Repo**: <https://github.com/Comfy-Org/comfy-cli>
- **Shell completion**: `comfy --install-completion`

**Use for**: installing/managing ComfyUI instances, custom nodes, models, snapshots, workflow dependencies.

<!-- AI-CONTEXT-END -->

## Installation

Prerequisites: Python >= 3.9, git, CUDA or ROCm (GPU).

```bash
pip install comfy-cli                          # any platform
brew install comfy-org/comfy-cli/comfy-cli     # macOS/Linux

conda create -n comfy-env python=3.11 && conda activate comfy-env
comfy install
```

## Commands

### Core

| Command | Description |
|---------|-------------|
| `comfy install` | Install ComfyUI |
| `comfy launch` | Start server |
| `comfy launch -- --listen 0.0.0.0 --port 8188` | Launch with custom flags |

### Custom Nodes

| Command | Description |
|---------|-------------|
| `comfy node install/uninstall/update/reinstall <name>` | Manage nodes |
| `comfy node enable/disable <name>` | Toggle without removing |
| `comfy node show <filter>` | List nodes (`installed`, `all`, `enabled`, `disabled`, `snapshot`) |
| `comfy node fix <name>` | Fix node dependencies |
| `comfy node install-deps [--workflow flow.json\|--deps deps.json]` | Install deps |
| `comfy node deps-in-workflow --workflow flow.json --output deps.json` | Extract deps |
| `comfy node save-snapshot [--output snap.json]` | Save environment snapshot |
| `comfy node restore-snapshot <path>` | Restore snapshot |
| `comfy node restore-dependencies` | Restore all node dependencies |

Node subcommands support `--channel TEXT` and `--mode remote|local|cache`.

### Models

| Command | Description |
|---------|-------------|
| `comfy model download --url <url> [--relative-path models/loras]` | Download model |
| `comfy model list [--relative-path models/loras]` | List models |
| `comfy model remove --model-names "model.safetensors"` | Remove model |

### Tracking

```bash
comfy tracking disable   # opt out of usage analytics
```

## Helper Script

`comfy-cli-helper.sh` wraps comfy-cli with aidevops conventions:

```bash
comfy-cli-helper.sh status                              # check installation
comfy-cli-helper.sh install                             # install comfy-cli
comfy-cli-helper.sh setup [--path /path/to/comfyui]    # install ComfyUI
comfy-cli-helper.sh launch [--port 8188] [--listen 0.0.0.0]
comfy-cli-helper.sh node-install <name>
comfy-cli-helper.sh model-download <url> [relative-path]
comfy-cli-helper.sh snapshot-save [--output file.json]
comfy-cli-helper.sh snapshot-restore <file.json>
comfy-cli-helper.sh workflow-deps <workflow.json>
comfy-cli-helper.sh node-list [installed|all|enabled|disabled]
comfy-cli-helper.sh model-list [relative-path]
```

## Common Workflows

```bash
# Fresh setup
comfy-cli-helper.sh install && comfy-cli-helper.sh setup --path ~/comfyui && comfy-cli-helper.sh launch

# Reproduce a workflow
comfy-cli-helper.sh workflow-deps workflow.json
comfy-cli-helper.sh model-download "https://civitai.com/api/download/models/12345" models/checkpoints
comfy-cli-helper.sh launch

# Backup/restore environment
comfy-cli-helper.sh snapshot-save --output my-setup.json
comfy-cli-helper.sh snapshot-restore my-setup.json
```

## Integration

- `content/production/image.md`, `content/production/video.md` — local ComfyUI generation pipeline
- `tools/vision/image-generation.md` — local model inference
- `tools/video/` — local video generation workflows

## Related

- `tools/vision/overview.md` — Vision AI decision tree
- `tools/video/higgsfield.md` — Cloud-based AI generation
