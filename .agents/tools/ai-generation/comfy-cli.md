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
- **Install comfy-cli**: `pip install comfy-cli` or `brew install comfy-org/comfy-cli/comfy-cli`
- **Docs**: <https://docs.comfy.org/comfy-cli/getting-started>
- **Repo**: <https://github.com/Comfy-Org/comfy-cli>
- **Shell completion**: `comfy --install-completion`

**When to use**:

- Installing and managing ComfyUI instances
- Installing/updating custom nodes
- Downloading and organizing models
- Saving/restoring environment snapshots
- Resolving workflow dependencies
- Launching ComfyUI with custom flags

<!-- AI-CONTEXT-END -->

## Installation

### Prerequisites

- Python >= 3.9
- git
- CUDA or ROCm (for GPU acceleration)

### Install comfy-cli

```bash
# Option 1: pip (any platform)
pip install comfy-cli

# Option 2: Homebrew (macOS/Linux)
brew tap Comfy-Org/comfy-cli
brew install comfy-org/comfy-cli/comfy-cli

# Enable shell completion
comfy --install-completion
```

### Install ComfyUI

```bash
# Create and activate a virtual environment
conda create -n comfy-env python=3.11
conda activate comfy-env

# Install ComfyUI
comfy install
```

## Commands

### Core

| Command | Description |
|---------|-------------|
| `comfy install` | Install ComfyUI into current environment |
| `comfy launch` | Start ComfyUI server |
| `comfy launch -- --listen 0.0.0.0 --port 8188` | Launch with custom flags |

### Custom Nodes

| Command | Description |
|---------|-------------|
| `comfy node install <name>` | Install a custom node |
| `comfy node uninstall <name>` | Remove a custom node |
| `comfy node update <name>` | Update a custom node |
| `comfy node reinstall <name>` | Reinstall a custom node |
| `comfy node enable <name>` | Enable a disabled node |
| `comfy node disable <name>` | Disable a node without removing |
| `comfy node show installed` | List installed nodes |
| `comfy node show all` | List all available nodes |
| `comfy node fix <name>` | Fix dependencies for a node |
| `comfy node install-deps` | Install deps from spec file |

**Node show filters**: `installed`, `enabled`, `not-installed`, `disabled`, `all`, `snapshot`, `snapshot-list`

### Models

| Command | Description |
|---------|-------------|
| `comfy model download --url <url>` | Download a model |
| `comfy model download --url <url> --relative-path models/loras` | Download to specific folder |
| `comfy model list` | List downloaded models |
| `comfy model list --relative-path models/loras` | List models in specific folder |
| `comfy model remove --model-names "model.safetensors"` | Remove a model |

### Snapshots

| Command | Description |
|---------|-------------|
| `comfy node save-snapshot` | Save current environment snapshot |
| `comfy node save-snapshot --output snap.json` | Save to specific file |
| `comfy node restore-snapshot <path>` | Restore from snapshot |
| `comfy node restore-dependencies` | Restore all node dependencies |

### Workflow Dependencies

| Command | Description |
|---------|-------------|
| `comfy node deps-in-workflow --workflow flow.json --output deps.json` | Extract workflow deps |
| `comfy node install-deps --workflow flow.json` | Install deps from workflow |
| `comfy node install-deps --deps deps.json` | Install deps from spec file |

### Tracking

| Command | Description |
|---------|-------------|
| `comfy tracking disable` | Disable usage analytics |
| `comfy tracking enable` | Enable usage analytics |

## Helper Script

The `comfy-cli-helper.sh` wraps comfy-cli with aidevops conventions:

```bash
# Check if comfy-cli is installed
comfy-cli-helper.sh status

# Install comfy-cli
comfy-cli-helper.sh install

# Install ComfyUI into a project directory
comfy-cli-helper.sh setup [--path /path/to/comfyui]

# Launch ComfyUI
comfy-cli-helper.sh launch [--port 8188] [--listen 0.0.0.0]

# Install a custom node
comfy-cli-helper.sh node-install <node-name>

# Download a model
comfy-cli-helper.sh model-download <url> [relative-path]

# Save environment snapshot
comfy-cli-helper.sh snapshot-save [--output file.json]

# Restore environment snapshot
comfy-cli-helper.sh snapshot-restore <file.json>

# Install workflow dependencies
comfy-cli-helper.sh workflow-deps <workflow.json>

# List installed nodes
comfy-cli-helper.sh node-list [installed|all|enabled|disabled]

# List downloaded models
comfy-cli-helper.sh model-list [relative-path]
```

## Common Workflows

### Fresh Setup

```bash
comfy-cli-helper.sh install
comfy-cli-helper.sh setup --path ~/comfyui
comfy-cli-helper.sh launch
```

### Reproduce a Workflow

```bash
# Extract and install all dependencies from a workflow file
comfy-cli-helper.sh workflow-deps workflow.json

# Download required models
comfy-cli-helper.sh model-download "https://civitai.com/api/download/models/12345" models/checkpoints

# Launch and run
comfy-cli-helper.sh launch
```

### Environment Backup/Restore

```bash
# Save current state
comfy-cli-helper.sh snapshot-save --output my-setup.json

# Restore on another machine
comfy-cli-helper.sh snapshot-restore my-setup.json
```

## Integration with aidevops

- **Content pipeline**: Used by `content/production/image.md` and `content/production/video.md` for local ComfyUI-based generation
- **Vision tools**: Complements `tools/vision/image-generation.md` for local model inference
- **Video tools**: Pairs with `tools/video/` for local video generation workflows
- **Model management**: Download and organize models referenced in workflow JSON files

## Node Options

All node subcommands support these options:

| Option | Description |
|--------|-------------|
| `--channel TEXT` | Specify the operation mode |
| `--mode TEXT` | `remote`, `local`, or `cache` |

## Related

- `tools/vision/overview.md` - Vision AI decision tree
- `tools/video/higgsfield.md` - Cloud-based AI generation
- `content/production/image.md` - Image production pipeline
- `content/production/video.md` - Video production pipeline
