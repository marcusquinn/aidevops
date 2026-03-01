# t1369: Add PaddleOCR Integration for Screenshot/Scene Text OCR

## Origin

- **Created:** 2026-03-01
- **Session:** Claude Code (interactive)
- **Created by:** human (interactive)
- **Conversation context:** User asked whether PaddleOCR was in aidevops. Comparison revealed our stack (MinerU + Docling + ExtractThinker) handles document parsing well but lacks scene text OCR — reading text from screenshots, photos, signs, UI captures. User anticipates screenshot reading needs and wants PaddleOCR added.

## What

Add PaddleOCR as a specialist OCR tool in aidevops, focused on **scene text / screenshot OCR** — the capability gap our current stack doesn't cover. Deliverables:

1. **Subagent doc** at `.agents/tools/ocr/paddleocr.md` — installation, CLI usage, Python API, model selection (PP-OCRv5 for text recognition, PaddleOCR-VL for document understanding), MCP server setup, integration patterns with existing document pipeline
2. **Helper script** at `.agents/scripts/paddleocr-helper.sh` — install, ocr (image/screenshot), serve (MCP server), status, models (list/pull)
3. **OCR overview doc** at `.agents/tools/ocr/overview.md` — tool selection guide: when to use PaddleOCR vs MinerU vs Docling vs LibPDF text extraction
4. **Update existing docs** — add OCR row to PDF overview tool selection table, update document-extraction.md with PaddleOCR as alternative OCR backend, update subagent-index.toon and AGENTS.md domain index
5. **MCP server integration** — document PaddleOCR's native MCP server for Claude Desktop / agent framework integration

## Why

- **Gap:** No tool in aidevops can read text from screenshots, photos, UI captures, or scene images. MinerU/Docling are document parsers, not scene text OCR engines.
- **Use cases:** Screenshot-based QA (read error messages, verify UI text), extracting text from photos/receipts/signs, processing user-submitted images, automated visual testing verification.
- **Timing:** PaddleOCR 3.4.0 (Jan 2026) ships a native MCP server, making integration with our agent framework straightforward. 71k stars, Apache-2.0, actively maintained.
- **Complementary:** Doesn't replace MinerU/Docling — fills a different niche. PaddleOCR for scene text, MinerU for document-to-markdown, Docling for structured extraction.

## How (Approach)

1. Create `.agents/tools/ocr/` directory (new domain)
2. Write `paddleocr.md` subagent doc following existing patterns (see `tools/conversion/mineru.md` for structure)
3. Write `overview.md` tool selection guide (see `tools/pdf/overview.md` for pattern)
4. Write `paddleocr-helper.sh` following existing helper patterns (see `local-model-helper.sh` for install/serve/status pattern)
5. Update cross-references in existing docs
6. Test installation and basic OCR on macOS (Apple Silicon)

**Key technical decisions:**
- Install via `pip install paddleocr` (or `uv pip install paddleocr`) — PaddlePaddle framework is a dependency
- Default to PP-OCRv5 for text recognition (lightweight, 100+ languages)
- Document PaddleOCR-VL (0.9B VLM) as optional for document understanding tasks
- MCP server: document both local Python library mode and stdio mode for Claude Desktop
- Helper script manages installation, model downloads, and MCP server lifecycle

**Reference files:**
- `.agents/tools/conversion/mineru.md` — similar subagent structure
- `.agents/tools/pdf/overview.md` — tool selection table pattern
- `.agents/scripts/local-model-helper.sh` — install/serve/status CLI pattern
- `.agents/tools/document/document-extraction.md` — Docling integration to cross-reference

## Acceptance Criteria

- [ ] `.agents/tools/ocr/paddleocr.md` exists with: install instructions, CLI usage, Python API examples, model selection guide, MCP server setup, screenshot OCR workflow
  ```yaml
  verify:
    method: codebase
    pattern: "paddleocr"
    path: ".agents/tools/ocr/paddleocr.md"
  ```
- [ ] `.agents/tools/ocr/overview.md` exists with tool selection table covering PaddleOCR, MinerU, Docling, LibPDF
  ```yaml
  verify:
    method: codebase
    pattern: "PaddleOCR.*MinerU.*Docling"
    path: ".agents/tools/ocr/overview.md"
  ```
- [ ] `.agents/scripts/paddleocr-helper.sh` exists with install, ocr, serve, status subcommands, ShellCheck clean
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/paddleocr-helper.sh"
  ```
- [ ] Subagent index updated with OCR entries
  ```yaml
  verify:
    method: codebase
    pattern: "paddleocr"
    path: ".agents/subagent-index.toon"
  ```
- [ ] AGENTS.md domain index updated with OCR row
  ```yaml
  verify:
    method: codebase
    pattern: "OCR.*tools/ocr"
    path: ".agents/AGENTS.md"
  ```
- [ ] PDF overview.md updated with PaddleOCR in tool selection table
  ```yaml
  verify:
    method: codebase
    pattern: "PaddleOCR"
    path: ".agents/tools/pdf/overview.md"
  ```
- [ ] `paddleocr` installs successfully on macOS Apple Silicon
  ```yaml
  verify:
    method: manual
    prompt: "Run 'pip install paddleocr' and verify import works"
  ```
- [ ] Screenshot OCR produces readable text output from a test image
  ```yaml
  verify:
    method: manual
    prompt: "Run paddleocr-helper.sh ocr on a screenshot and verify text extraction"
  ```

## Context & Decisions

- **Why PaddleOCR over Tesseract:** PaddleOCR has significantly better accuracy on scene text (photos, screenshots, varied lighting), supports 100+ languages natively, has active development (v3.4.0 Jan 2026), and ships an MCP server. Tesseract is legacy and struggles with non-document images.
- **Why PaddleOCR over EasyOCR:** PaddleOCR has 71k stars vs EasyOCR's 24k, more active development, better accuracy benchmarks, native MCP server, and broader model ecosystem (VLM, structure parsing).
- **Why not replace MinerU/Docling:** Different tools for different jobs. MinerU excels at document-to-markdown with layout preservation. Docling excels at structured extraction with LLM integration. PaddleOCR excels at raw text recognition from any image. They complement each other.
- **PaddlePaddle dependency:** PaddleOCR requires the PaddlePaddle ML framework (~500MB). This is the main cost. Documented as optional install — only needed when OCR capability is required.
- **MCP server:** PaddleOCR 3.1.0+ ships a native MCP server supporting both OCR and PP-StructureV3 pipelines. Three modes: local Python library, cloud service, self-hosted. This is a significant integration advantage.

## Relevant Files

- `.agents/tools/conversion/mineru.md` — pattern for subagent doc structure
- `.agents/tools/pdf/overview.md` — pattern for tool selection guide
- `.agents/tools/document/document-extraction.md` — Docling integration, cross-reference target
- `.agents/scripts/local-model-helper.sh` — pattern for install/serve/status helper
- `.agents/AGENTS.md` — domain index to update
- `.agents/subagent-index.toon` — subagent registry to update

## Dependencies

- **Blocked by:** none
- **Blocks:** future screenshot-based QA workflows, visual testing verification, receipt/photo OCR pipelines
- **External:** PaddlePaddle framework (pip install), PaddleOCR models (auto-downloaded on first use, ~100-500MB depending on model)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | PaddleOCR docs, MCP server setup, model selection |
| Implementation | 3h | Subagent doc, overview doc, helper script |
| Cross-references | 30m | Update existing docs, index, AGENTS.md |
| Testing | 1h | Install verification, screenshot OCR test |
| **Total** | **5h** | |
