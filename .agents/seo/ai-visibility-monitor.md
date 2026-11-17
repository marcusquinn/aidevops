<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# AI Visibility Monitor

Use this leaf to code dated, approved AI-answer captures. It is an offline
measurement tool, not a scraper, provider client, crawler, or factual verifier.

## Collection boundary

- Use only an approved read-only provider or browser route after its readiness and
  authority checks. Keep API and consumer-UI observations on separate engine/mode
  lines; never use a normal signed-in profile or arbitrary endpoint.
- When a route is unsupported, import supplied captures and record `unavailable`.
  Failed or unavailable collection is not a negative answer and never enters a
  valid-answer denominator. No account creation, subscriptions, scheduled crawling
  or live calls are supported by this helper.
- Preserve exact prompt, cohort, engine/product/model (or `unknown`), mode,
  locale/language, timestamp, session context, outcome status and raw source ID.

## Provider routes

Paid APIs that return AI answers with their cited sources. The helper does not
call them: run approved requests separately, then map each response to the
capture fields above (provider request or task ID as the raw source ID) and
import it. Facts checked 2026-11-17; confirm prices before a budget.

- **cloro** ([docs](https://cloro.dev/docs)): sync `POST https://api.cloro.dev/v1/monitor/{chatgpt,gemini,aimode,bing/aimode}`
  with a `prompt` and `country`; Google's AI Overview comes from
  `/v1/monitor/google` with `include.aioverview`. Answers return as text or
  Markdown with sources and citation pills. Sync credits: ChatGPT 5 + 2
  surcharge, Gemini, Google AI Mode and Bing AI Mode 4 + 2, Google Search with
  AI Overview 3 + 2 + 2; failed requests are not billed. Batches: the async API
  has no surcharge. `POST /v1/async/task` (or `/v1/async/task/batch`, up to 500)
  takes `taskType` (`CHATGPT`, `GEMINI`, `AIMODE`, `BING_AIMODE`, `GOOGLE`) and
  `payload` (the sync request body) and returns a task ID; get the result from
  `GET /v1/async/task/{taskId}` or a `webhook.url` POST. Finished tasks are
  deleted about 24 hours after creation, so import results the same day.
  Free accounts get 500 credits a month and one concurrent request.
  `GET /v1/credits` (balance) and `GET /v1/countries?model=` (where an engine
  answers) are free. Requests run real logged-out browser sessions through a
  proxy in the chosen country, and the engine picks the model: code them as
  logged-out consumer-UI observations, model `unknown` unless returned, one line
  per engine and search setting. ChatGPT forces web search unless
  `disableWebSearch: true`, which gives different answers and often no sources:
  record it in the mode. Allow 300 s per sync request. No Perplexity, Copilot,
  Grok or Claude. Key: store `CLORO_<ACCOUNT>_API_KEY` (`aidevops/onboarding.md`)
  and inject it as `CLORO_API_KEY`, the Bearer variable the Python SDK reads.
  Hosted MCP: `https://mcp.cloro.dev/mcp` with OAuth or an `Authorization`
  header; never use the key-in-path URL form.
- **Oxylabs Web API**: async-only `POST /v1/async/scrape/{chatgpt,gemini,perplexity}`.
  Request `output: ["json"]` (ChatGPT and Gemini default to HTML) and map the
  parsed answer, citations and model from `results[].json`. ChatGPT takes
  `search: true|false` (browsing or training data only), so record it as the
  mode. Billing and key: `tools/research/web-search-apis.md` "Other providers".

## Offline workflow

```bash
python3 .agents/scripts/ai-visibility-helper.py import --input captures.json --dry-run
python3 .agents/scripts/ai-visibility-helper.py analyze --input captures.json --decisions brands.json --dry-run
```

`brands.json` contains a small, commercially relevant `brands` list. The report
keeps mention, recommendation, citation and sentiment distinct; citations show
visible source selection only and do not verify claims or prove endorsement.

For projects with `context/keywords.md`, use the registry `queries` as the prompt
set and import captures into history with
`aidevops keywords track --source ai --file captures.json` (brands from
`role=self` entities; citations counted for front-matter `domains`). Rollups set
`mention_rate` and `citation_rate` per question (`seo/keywords-standard.md`).

## Reporting

Read `.agents/seo/ai-search-scoring.md` and
`.agents/seo/seo-geo-experiment-design.md` before interpreting results. Show each
engine/mode/cohort component table before any aggregate, including captures, valid
answers, failed/unavailable counts, completion coverage, observed brands,
recommendations, citations and source types. Repeats are not independent users;
compare controlled cohorts and report variation rather than causality or hidden
retrieval visibility.
