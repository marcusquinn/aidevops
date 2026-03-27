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
- **Tool**: `unstract_tool` - submits files to Unstract API, polls for completion, returns structured JSON
- **Credentials**: `UNSTRACT_API_KEY` + `API_BASE_URL` in `~/.config/aidevops/credentials.sh` (chmod 600)
- **Docs**: https://docs.unstract.com/unstract/unstract_platform/mcp/unstract_platform_mcp_server/
- **GitHub**: https://github.com/Zipstack/unstract
- **On-demand loading**: MCP disabled globally; enabled per-agent when document extraction is needed
- **Trigger keywords**: document, extract, parse, invoice, statement, PDF, OCR, unstructured

<!-- AI-CONTEXT-END -->

## Supported File Types

| Category | Formats |
|----------|---------|
| Documents | PDF, DOCX, DOC, ODT, TXT, CSV, JSON |
| Spreadsheets | XLSX, XLS, ODS |
| Presentations | PPTX, PPT, ODP |
| Images | PNG, JPG, JPEG, TIFF, BMP, GIF, WEBP |

## MCP Tool

### `unstract_tool`

Submits a file to the Unstract API, polls for completion, and returns structured extraction results.

**Parameters**:
- `file_path` (required): Path to the document to process
- `include_metadata` (optional): Include extraction metadata in response
- `include_metrics` (optional): Include processing metrics (tokens, cost)

**Example prompt**: "Process the document /tmp/invoice.pdf"

## Setup

### Option A: Cloud (Quick Start)

1. Sign up at https://unstract.com/start-for-free/ (14-day free trial)
2. Create a Prompt Studio project, define extraction schema, deploy as API endpoint
3. Add credentials to `~/.config/aidevops/credentials.sh` (chmod 600):

```bash
export UNSTRACT_API_KEY="your_api_key_here"
export API_BASE_URL="https://us-central.unstract.com/deployment/api/your-deployment-id/"
```

### Option B: Self-Hosted (Local) - Recommended

Requires Docker, 8GB RAM. Full data privacy — no documents leave your machine.

```bash
~/.aidevops/agents/scripts/unstract-helper.sh install
# Or: ~/.aidevops/agents/scripts/setup-mcp-integrations.sh unstract
```

Clones to `~/.aidevops/unstract/`, disables analytics, starts Docker Compose. Visit http://frontend.unstract.localhost (login: unstract/unstract)

**Management:**

```bash
unstract-helper.sh start|stop|status|logs|configure-llm|uninstall
```

Set credentials pointing at local instance:

```bash
export UNSTRACT_API_KEY="your_api_key_here"
export API_BASE_URL="http://backend.unstract.localhost/deployment/api/your-id/"
```

**Note**: The MCP expects `API_BASE_URL` (not prefixed). This matches the official Unstract spec.

### LLM Adapters (Self-Hosted)

Add existing API keys as adapters in Unstract UI (Settings > Adapters). Run `unstract-helper.sh configure-llm` to see configured keys.

| Your Key | Unstract Adapter |
|----------|-----------------|
| `OPENAI_API_KEY` | OpenAI (GPT-4, GPT-4o) |
| `ANTHROPIC_API_KEY` | Anthropic (Claude) |
| `GOOGLE_API_KEY` / Vertex credentials | Google VertexAI / Gemini |
| `AZURE_OPENAI_API_KEY` | Azure OpenAI |
| AWS credentials | AWS Bedrock |
| Ollama (local, no key) | Ollama (http://host.docker.internal:11434) |

For fully local/offline operation, use **Ollama** — no cloud API keys needed.

### OpenCode / Claude Desktop Configuration

- **OpenCode**: See `configs/mcp-templates/unstract.json` (on-demand, disabled globally)
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

- **Invoice processing**: Extract line items, totals, vendor info
- **Bank statement parsing**: Structure transaction data from varied formats
- **Insurance claims**: Extract claim details from forms and supporting documents
- **KYC/onboarding**: Parse identity documents and application forms
- **Contract analysis**: Extract key terms, dates, parties from legal documents

## Analytics / Telemetry

The `unstract/mcp-server` Docker image has no telemetry. For self-hosted, disable frontend analytics: set `REACT_APP_ENABLE_POSTHOG=false` in `frontend/.env`. The cloud API may collect server-side usage metrics — use self-hosted if this is a concern.

## Related

- `tools/context/mcp-discovery.md` - On-demand MCP loading pattern
- `.agents/aidevops/mcp-integrations.md` - All MCP integrations
- `configs/mcp-templates/unstract.json` - OpenCode config template
