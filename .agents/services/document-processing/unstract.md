---
description: Unstract - LLM-powered document data extraction via MCP
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  unstract_tool: true
mcp:
  unstract: true
---

# Unstract - Document Processing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Extract structured data from unstructured documents (PDFs, images, DOCX, etc.)
- **MCP Server**: `unstract/mcp-server` (Docker) or `@unstract/mcp-server` (npx)
- **Tool**: `unstract_tool` — submit file to Unstract API, poll for completion, return structured JSON
- **Credentials**: `UNSTRACT_API_KEY` + `API_BASE_URL` in `~/.config/aidevops/credentials.sh` (chmod 600)
- **Docs**: https://docs.unstract.com/unstract/unstract_platform/mcp/unstract_platform_mcp_server/
- **GitHub**: https://github.com/Zipstack/unstract
- **Loading**: MCP disabled globally; enabled per-agent when document extraction needed
- **Trigger keywords**: document, extract, parse, invoice, statement, PDF, OCR, unstructured

<!-- AI-CONTEXT-END -->

## Supported File Types

PDF, DOCX, DOC, ODT, TXT, CSV, JSON, XLSX, XLS, ODS, PPTX, PPT, ODP, PNG, JPG, JPEG, TIFF, BMP, GIF, WEBP

## MCP Tool: `unstract_tool`

| Parameter | Required | Description |
|-----------|----------|-------------|
| `file_path` | yes | Path to document |
| `include_metadata` | no | Include extraction metadata |
| `include_metrics` | no | Include processing metrics (tokens, cost) |

**Example prompt**: "Process the document /tmp/invoice.pdf"

## Setup

### Option A: Cloud (Quick Start)

1. Sign up at https://unstract.com/start-for-free/ (14-day free trial)
2. Create Prompt Studio project, define extraction schema, deploy as API endpoint
3. Store credentials (preferred: `setup-local-api-keys.sh`; or manually in `credentials.sh`):

```bash
export UNSTRACT_API_KEY="your_api_key_here"
export API_BASE_URL="https://us-central.unstract.com/deployment/api/your-deployment-id/"
```

### Option B: Self-Hosted (Recommended)

Requires Docker, 8GB RAM. Full data privacy — no documents leave your machine.

```bash
~/.aidevops/agents/scripts/unstract-helper.sh install
# Or: ~/.aidevops/agents/scripts/setup-mcp-integrations.sh unstract
```

Clones to `~/.aidevops/unstract/`, disables analytics, starts Docker Compose. Visit http://frontend.unstract.localhost (login: unstract/unstract).

**Management:** `unstract-helper.sh start|stop|status|logs|configure-llm|uninstall`

Set credentials for local instance (preferred: `setup-local-api-keys.sh`; or manually):

```bash
export UNSTRACT_API_KEY="your_api_key_here"
export API_BASE_URL="http://backend.unstract.localhost/deployment/api/your-id/"
```

MCP expects `API_BASE_URL` (not prefixed) — matches official Unstract spec.

### LLM Adapters (Self-Hosted)

Add API keys as adapters in Unstract UI (Settings > Adapters). Run `unstract-helper.sh configure-llm` to see configured keys.

| Your Key | Unstract Adapter |
|----------|-----------------|
| `OPENAI_API_KEY` | OpenAI (GPT-4, GPT-4o) |
| `ANTHROPIC_API_KEY` | Anthropic (Claude) |
| `GOOGLE_API_KEY` / Vertex credentials | Google VertexAI / Gemini |
| `AZURE_OPENAI_API_KEY` | Azure OpenAI |
| AWS credentials | AWS Bedrock |
| Ollama (local, no key) | Ollama (http://host.docker.internal:11434) |

For fully local/offline operation, use **Ollama** — no cloud API keys needed.

### Runtime Configuration

- **Claude Code / OpenCode**: See `configs/mcp-templates/unstract.json` (on-demand, disabled globally)
- **Claude Desktop** (Docker):

```json
{
  "mcpServers": {
    "unstract_tool": {
      "command": "/usr/local/bin/docker",
      "args": ["run", "-i", "--rm", "-v", "/tmp:/tmp",
               "-e", "UNSTRACT_API_KEY", "-e", "API_BASE_URL",
               "unstract/mcp-server", "unstract"],
      "env": {
        "UNSTRACT_API_KEY": "",
        "API_BASE_URL": "https://us-central.unstract.com/deployment/api/.../"
      }
    }
  }
}
```

## Use Cases

- **Invoice/statement processing**: Extract line items, totals, vendor/transaction data
- **KYC/onboarding**: Parse identity documents, application forms, insurance claims
- **Contract analysis**: Extract key terms, dates, parties from legal documents

## Telemetry

`unstract/mcp-server` Docker image: no telemetry. Self-hosted: set `REACT_APP_ENABLE_POSTHOG=false` in `frontend/.env`. Cloud API may collect server-side metrics — use self-hosted if concerned.

## Related

- `tools/context/mcp-discovery.md` — on-demand MCP loading pattern
- `.agents/aidevops/mcp-integrations.md` — all MCP integrations
- `configs/mcp-templates/unstract.json` — config template
