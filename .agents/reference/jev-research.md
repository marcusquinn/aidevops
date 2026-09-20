<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Jev research ledger

Research date: **2026-09-20**. This is evidence and inspiration, not runtime
instructions or an endorsement of externally supplied code. Recheck mutable
models, licences, commercial terms and availability before adopting them. No
private account identity, keys, customer data or live benchmark results belong here.

## Primary sources

| Source | Finding at review |
| --- | --- |
| [TypeSafe](https://typesafe.ai/) / [introduction](https://docs.typesafe.ai/introduction) | Structured decisions rather than prose; vendor performance claims are not our benchmarks |
| [API](https://docs.typesafe.ai/api.md) | POST `https://api.typesafe.ai/v1/systemone`; Choice, Score and Noul |
| [Models](https://docs.typesafe.ai/models.md) | `jev-1.13.0`; text-only; $0.042/M input, free output; 64K combined, state plus longest question at most 32K; dynamic quotas |
| [Confidence](https://docs.typesafe.ai/confidence) | Distribution-derived confidence is distinct from probability and measured task accuracy |
| [Known limitations](https://docs.typesafe.ai/model-jaggedness/jev-1.13.md) | Adversarial state can steer decisions; counting, dates, indirection and irrelevant context are weak points |
| [Legal index](https://docs.typesafe.ai/legal.md) | Enterprise ZDR offered, not a default account guarantee |
| [Privacy](https://typesafe.ai/legal/privacy-policy) / [DPA](https://typesafe.ai/legal/data-processing) | No input training commitment; US processing; retention not a fixed deletion period; DPA includes EU/UK transfer provisions |
| [Customer agreement](https://typesafe.ai/legal/mca) | Sections 2.1–2.2 permit application integration; 2.3 restricts distillation/imitation/competing development and publication of benchmarks/performance; 4.3 defines broad telemetry rights |
| [Vercel catalog](https://vercel.com/ai-gateway/models) | Lists `typesafe-ai/jev` as evaluation; listing is not account readiness or evidence that Vercel hosts weights |

Cloudflare Workers AI / AI Gateway availability was **unverified**, not proven
absent. Running a Worker which calls the TypeSafe API is different from hosting Jev
on Workers AI. Original Jev weights and a self-hosting licence were not established.
TypeSafe documents no customer fine-tuning of Jev itself. Resolve contractual
questions with the provider before private-data use, public performance reporting
or any project training from service outputs. This ledger is not legal advice.

## Community projects

| Project | Useful idea | Qualification |
| --- | --- | --- |
| [simple-jev](https://github.com/featherless-ai/simple-jev) / [demo](https://simple-jev.featherless.ai/) | Shared prefix/KV reuse and constrained token probabilities over other models | Not original Jev; licence unconfirmed in review; never submit private data to the public demo |
| [jevmlx](https://github.com/bnsd55/jevmlx) | Local Apple Silicon structured classification using MLX | MIT at review; model licences separate; approximate interface, not equivalent calibration |
| [jev-ultrafast](https://github.com/browser-use/jev-ultrafast) | Batched action/target decisions, reduced browser round trips | Real TypeSafe API; MIT at review; task-specific speed evidence, incomplete browser feature coverage |
| [jev-cdp](https://github.com/kbitgood/jev-cdp) | Bun/TypeScript CDP adaptation | Real API; MIT at review; powerful browser access demands isolation |
| [fast-jev-compaction](https://github.com/tamaratran/fast-jev-compaction) | Retain/discard decisions for tool history | Not adopted: external conversation-derived state and possible loss of needed evidence |
| [Fireworks classifier article](https://fireworks.ai/blog/Finetuning-LLMs-as-Classifiers) | Token labels, LoRA, classification probabilities | Independent-model research, not a Jev implementation or general $2 production cost estimate |

Repository findings came from read-only source research, not execution or a full
security audit. Do not install community hooks from these links automatically.
Open weights of a base model do not establish a right to copy service behaviour
using Jev responses; train independent alternatives only on appropriately licensed,
independently obtained data and review the applicable agreements.

## Social context

- [Richelle Ji: open-model classification](https://x.com/Richelle_Ji/status/2101064292242219407?s=20)
  and [SimpleJev details](https://x.com/Richelle_Ji/status/2101068835038392329?s=20):
  inspiration for Jev-like interfaces and vision-capable base models, not evidence
  that TypeSafe Jev supports images or released its weights.
- [Will Brown: premature stopping](https://x.com/willcb/status/2101178888441516117?s=20)
  and [continuation question](https://x.com/willcb/status/2101195579204448750?s=20):
  inspiration for a bounded advisory nudge, not proof that premature stopping is
  universally solved. Implemented guidance requires authority checks and a 12-nudge
  ceiling; no runtime hook is installed.
