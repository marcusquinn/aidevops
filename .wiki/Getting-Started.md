# Getting Started

Complete guide to installing and configuring the AI DevOps Framework.

## Prerequisites

### System Requirements

- **Operating System**: macOS, Linux (Ubuntu/Debian)
- **Shell**: Bash 4.0+
- **Git**: Version control system
- **SSH**: Secure shell access

### Required Tools

```bash
# macOS
brew install sshpass jq curl mkcert dnsmasq

# Ubuntu/Debian
sudo apt-get install sshpass jq curl dnsmasq

# Verify installations
sshpass -V
jq --version
curl --version
```

## Installation

### 1. Clone Repository

```bash
mkdir -p ~/git
cd ~/git
git clone https://github.com/marcusquinn/aidevops.git
cd aidevops
```

### 2. Run Setup Script

```bash
./setup.sh
```

The setup script will:

- Install required dependencies
- Create necessary directories
- Set up SSH configurations
- Copy configuration templates
- Initialize MCP integrations
- Configure quality control tools

### 3. Generate SSH Keys

```bash
# Generate Ed25519 key (recommended)
ssh-keygen -t ed25519 -C "your-email@domain.com"

# Or RSA key if Ed25519 not supported
ssh-keygen -t rsa -b 4096 -C "your-email@domain.com"

# Add to SSH agent
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

## Configuration

### Provider Setup

Each provider requires its own configuration file:

```bash
# Copy templates
cp configs/hostinger-config.json.txt configs/hostinger-config.json
cp configs/hetzner-config.json.txt configs/hetzner-config.json
cp configs/cloudflare-config.json.txt configs/cloudflare-config.json

# Edit with your credentials
nano configs/hostinger-config.json
```

### Configuration File Format

**Example**: `configs/hostinger-config.json`

```json
{
  "api_token": "your-api-token-here",
  "ssh_user": "your-username",
  "ssh_key": "~/.ssh/id_ed25519",
  "servers": [
    {
      "name": "example.com",
      "host": "example.com",
      "port": 22
    }
  ]
}
```

### File Permissions

```bash
# Secure configuration files
chmod 600 configs/*.json

# Verify permissions
ls -la configs/
```

## Testing Installation

### Test SSH Connections

```bash
# List all configured servers
./scripts/servers-helper.sh list

# Test specific provider
./providers/hostinger-helper.sh list
./providers/hetzner-helper.sh list
```

### Test API Connections

```bash
# Test Cloudflare API
./providers/dns-helper.sh cloudflare list-zones

# Test Spaceship API
./providers/spaceship-helper.sh check-availability example.com
```

### Run Quality Checks

```bash
# Install Qlty
curl -sSL https://qlty.sh/install | sh

# Run quality check
bash .agent/scripts/qlty-cli.sh check 10
```

## MCP Integration Setup

### Install MCP Servers

```bash
# Install all MCP integrations
bash .agent/scripts/setup-mcp-integrations.sh all

# Or install specific servers
bash .agent/scripts/setup-mcp-integrations.sh chrome-devtools
bash .agent/scripts/setup-mcp-integrations.sh context7
bash .agent/scripts/setup-mcp-integrations.sh pagespeed
```

### Configure AI Assistant

Add to your AI assistant's system prompt:

```text
Before any DevOps operations, read ~/git/aidevops/AGENTS.md for authoritative guidance
```

**Recommended CLI AI Assistants:**

- Qoder (Claude)
- Augment Code
- Claude Desktop
- Warp AI
- Factory AI
- OpenAI Codex

## First Steps

### 1. List Available Servers

```bash
./scripts/servers-helper.sh list
```

### 2. Connect to Server

```bash
# Hostinger
./providers/hostinger-helper.sh connect example.com

# Hetzner
./providers/hetzner-helper.sh connect main web-server
```

### 3. Execute Remote Command

```bash
./providers/hostinger-helper.sh exec example.com "uptime"
./providers/hetzner-helper.sh exec main web-server "df -h"
```

### 4. Manage DNS Records

```bash
# List DNS zones
./providers/dns-helper.sh cloudflare list-zones

# Add A record
./providers/dns-helper.sh cloudflare add-record example.com A 192.168.1.1
```

### 5. Run Performance Audit

```bash
./providers/pagespeed-helper.sh wordpress https://example.com
./providers/pagespeed-helper.sh lighthouse https://example.com json
```

## Common Use Cases

### Server Management

```bash
# List all servers
./scripts/servers-helper.sh list

# Execute command on all servers
./scripts/servers-helper.sh exec-all "uptime"

# Update all servers
./scripts/servers-helper.sh exec-all "apt-get update && apt-get upgrade -y"
```

### Domain Operations

```bash
# Check domain availability
./providers/spaceship-helper.sh check-availability newdomain.com

# Purchase domain
./providers/spaceship-helper.sh purchase newdomain.com

# Configure DNS
./providers/dns-helper.sh cloudflare add-record newdomain.com A 192.168.1.1
./providers/dns-helper.sh cloudflare add-record newdomain.com CNAME www newdomain.com
```

### WordPress Management

```bash
# List WordPress sites
./providers/mainwp-helper.sh list-sites

# Backup site
./providers/mainwp-helper.sh backup example.com

# Update plugins
./providers/mainwp-helper.sh update-plugins example.com
```

### Quality Control

```bash
# Run quality analysis
bash .agent/scripts/qlty-cli.sh check 10

# Apply automated fixes
bash .agent/scripts/qlty-cli.sh fix

# Format all files
export PATH="$HOME/.qlty/bin:$PATH"
qlty fmt
```

## Troubleshooting

### SSH Connection Issues

**Problem**: `Permission denied (publickey)`

**Solution**:

```bash
# Verify SSH key is added
ssh-add -l

# Add key if missing
ssh-add ~/.ssh/id_ed25519

# Test connection
ssh -v user@host
```

### API Authentication Errors

**Problem**: `401 Unauthorized`

**Solution**:

```bash
# Verify API token in config
cat configs/provider-config.json

# Check token permissions on provider dashboard
# Regenerate token if necessary
```

### Configuration File Errors

**Problem**: `Cannot read config file`

**Solution**:

```bash
# Verify file exists
ls -la configs/

# Check file permissions
chmod 600 configs/*.json

# Validate JSON syntax
jq . configs/provider-config.json
```

## Next Steps

- [Architecture Overview →](Architecture.md)
- [Provider Documentation →](Providers.md)
- [MCP Integrations →](MCP-Integrations.md)
- [Security Best Practices →](Security.md)

---

**Need Help?** Check the [Troubleshooting](../README.md#customization--troubleshooting) section or open an issue on GitHub.
