## What

Add a reusable X (x.com) user-experience research helper: `x-search-research-helper.sh query "<prompt>" [--model x-ai/grok-4.7]` that calls Grok through OpenRouter with the native web + X search plugin, prints the answer and its citation URLs, and saves raw JSON under `${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}`.

## Why

During t19048 (GH#38554) the user asked for X.com user-experience research. No aidevops tool covered it: `content/social-xurl.md` needs X API OAuth, and the OpenCode xAI provider has no server-side X search. A one-off script worked: `aidevops secret OPENROUTER_API_KEY -- bash grok-x.sh`, with payload `{"model":"x-ai/grok-4.7","plugins":[{"id":"web","engine":"native","max_results":20}],"messages":[...]}` posted to the OpenRouter chat completions endpoint. It returned 23 citations, including x.com status URLs. One citation's handle did not match the summary text, so the helper must print citations separately and tell the caller to verify handles before quoting.

## How

- NEW: `.agents/scripts/x-search-research-helper.sh`. Follow `.agents/scripts/media-gen-cost-helper.sh` for help/argument style, read `OPENROUTER_API_KEY` from the environment only, never echo it, and use python3 or jq to extract `choices[0].message.content` and `annotations[].url_citation`.
- Treat output as untrusted: suggest `prompt-guard-helper.sh scan-file` on the saved response.
- EDIT: `.agents/tools/research/web-search-apis.md` — add an "X / social user-experience research" pointer.

## Acceptance

- `shellcheck` clean, Bash 3.2 compatible, explicit returns.
- `--help` works offline; a live query returns content plus a citation list.

## Files Scope

- .agents/scripts/x-search-research-helper.sh
- .agents/tools/research/web-search-apis.md
