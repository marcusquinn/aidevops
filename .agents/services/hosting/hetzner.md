---
description: Hetzner Cloud server management via REST API
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

# Hetzner Cloud Provider

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Cloud VPS, dedicated servers, storage
- **API**: REST at `https://api.hetzner.cloud/v1`
- **Auth**: Bearer token per project (stored in `~/.config/aidevops/credentials.sh`)
- **Token format**: `HCLOUD_TOKEN_{PROJECT}` (e.g. `HCLOUD_TOKEN_MYPROJECT`)
- **Locations**: Germany (fsn1, nbg1), Finland (hel1), USA (ash, hil)
- **Server types**: CX (shared), CPX (dedicated vCPU), CCX (dedicated CPU)
- **Docs**: https://docs.hetzner.cloud/

**No MCP required** - this subagent uses curl directly. Zero context cost until invoked.

<!-- AI-CONTEXT-END -->

## Authentication

```bash
# Load token for a specific project
source ~/.config/aidevops/credentials.sh
export HCLOUD_TOKEN="$HCLOUD_TOKEN_MYPROJECT"

# Verify access
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/servers | python3 -c "
import json,sys
d=json.load(sys.stdin)
for s in d.get('servers',[]):
  print(f\"{s['id']:>10} {s['status']:<10} {s['server_type']:<8} {s['name']}\")"
```

## API Operations

### List Servers

```bash
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/servers | python3 -m json.tool
```

### Get Server Details

```bash
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/servers/{id} | python3 -m json.tool
```

### Server Actions

```bash
# Actions: poweron, poweroff, reboot, shutdown, reset_password
curl -s -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/servers/{id}/actions/{action}
```

### Create Server

```bash
curl -s -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-server",
    "server_type": "cx22",
    "image": "ubuntu-24.04",
    "location": "fsn1",
    "ssh_keys": ["my-key"]
  }' \
  https://api.hetzner.cloud/v1/servers
```

### Delete Server

```bash
curl -s -X DELETE -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/servers/{id}
```

### Volumes

```bash
# List
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/volumes

# Create
curl -s -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"data","size":50,"location":"fsn1","format":"ext4"}' \
  https://api.hetzner.cloud/v1/volumes
```

### Firewalls

```bash
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/firewalls
```

### SSH Keys

```bash
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/ssh_keys
```

### Snapshots & Backups

```bash
# Enable backups
curl -s -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/servers/{id}/actions/enable_backup

# Create snapshot
curl -s -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"description":"pre-upgrade"}' \
  https://api.hetzner.cloud/v1/servers/{id}/actions/create_image
```

### Server Types & Images

```bash
# Available server types
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/server_types | python3 -c "
import json,sys
for t in json.load(sys.stdin)['server_types']:
  print(f\"{t['name']:<10} {t['cores']}c {t['memory']:.0f}GB {t['description']}\")"

# Available images
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  "https://api.hetzner.cloud/v1/images?type=system&status=available" | python3 -c "
import json,sys
for i in json.load(sys.stdin)['images']:
  print(f\"{i['name']:<20} {i['description']}\")"
```

## Multi-Project Setup

Each Hetzner Cloud project gets its own API token. Store them in `~/.config/aidevops/credentials.sh`:

```bash
export HCLOUD_TOKEN_PROJECTA="hc_..."
export HCLOUD_TOKEN_PROJECTB="hc_..."
```

To get a token:
1. https://console.hetzner.cloud → Select project
2. Security → API Tokens → Generate API Token
3. Read & Write permissions → Copy token

## When to Enable the MCP Instead

For frequent interactive use, enable the MCP server in `opencode.json`:

```json
"hetzner-myproject": {
  "type": "local",
  "command": ["/bin/bash", "-c",
    "source ~/.config/aidevops/credentials.sh && HCLOUD_TOKEN=$HCLOUD_TOKEN_MYPROJECT /Users/you/.local/bin/mcp-hetzner"],
  "enabled": true
}
```

Install: `uv tool install 'mcp-hetzner @ git+https://github.com/dkruyt/mcp-hetzner.git'`

The MCP costs ~2K context tokens per session but provides richer tool integration.
