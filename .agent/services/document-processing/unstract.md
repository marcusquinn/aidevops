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
- **Credentials**: `UNSTRACT_API_KEY` + `API_BASE_URL` in `~/.config/aidevops/mcp-env.sh`
- **Docs**: https://docs.unstract.com/unstract/unstract_platform/mcp/unstract_platform_mcp_server/
- **GitHub**: https://github.com/Zipstack/unstract

**On-demand loading**: This MCP is disabled globally and enabled per-agent when document extraction is needed.

<!-- AI-CONTEXT-END -->

## What is Unstract?

Unstract is a no-code LLM platform that structures unstructured documents. It provides:

- **Prompt Studio**: Visual environment to define extraction schemas
- **API Deployments**: Turn any document into JSON via REST API
- **ETL Pipelines**: Batch process documents into databases
- **MCP Server**: Integrate extraction into AI agent workflows

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

### 1. Get API Credentials

1. Sign up at https://unstract.com/start-for-free/ (14-day free trial)
2. Create a Prompt Studio project and define your extraction schema
3. Deploy as an API endpoint
4. Copy the API key and deployment URL

### 2. Store Credentials

```bash
# Add to ~/.config/aidevops/mcp-env.sh:
export UNSTRACT_API_KEY="your_api_key_here"
export UNSTRACT_API_BASE_URL="https://us-central.unstract.com/deployment/api/your-deployment-id/"
```

### 3. OpenCode Configuration (On-Demand)

The MCP is configured in OpenCode but disabled globally. It loads on-demand when this subagent is invoked.

See `configs/mcp-templates/unstract.json` for the configuration template.

### 4. Claude Desktop Configuration (Docker)

```json
{
  "mcpServers": {
    "unstract_tool": {
      "command": "/usr/local/bin/docker",
      "args": [
        "run", "-i", "--rm",
        "-v", "/tmp:/tmp",
        "-e", "UNSTRACT_API_KEY",
        "-e", "API_BASE_URL",
        "unstract/mcp-server",
        "unstract"
      ],
      "env": {
        "UNSTRACT_API_KEY": "",
        "API_BASE_URL": "https://us-central.unstract.com/deployment/api/.../"
      }
    }
  }
}
```

## Use Cases

- **Invoice processing**: Extract line items, totals, vendor info from invoices
- **Bank statement parsing**: Structure transaction data from varied bank formats
- **Insurance claims**: Extract claim details from forms and supporting documents
- **KYC/onboarding**: Parse identity documents and application forms
- **Contract analysis**: Extract key terms, dates, parties from legal documents

## Integration with aidevops

This subagent is referenced by agents that need document extraction capabilities. The MCP loads only when document processing tasks are detected.

**Trigger keywords**: document, extract, parse, invoice, statement, PDF, OCR, unstructured

## Related

- `tools/context/mcp-discovery.md` - On-demand MCP loading pattern
- `.agent/aidevops/mcp-integrations.md` - All MCP integrations
- `configs/mcp-templates/unstract.json` - OpenCode config template
