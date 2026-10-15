#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Name-based inference for `aidevops secret organise` drafts (GH#34723).

Inference uses only the secret *name*; results are unconfirmed drafts with
the evidence that produced them.
"""

from __future__ import annotations

import re
from typing import Any

from credential_inventory_fields import DEFAULT_ENV

# Known name prefixes; first match wins, so longer prefixes come first.
PROVIDER_PREFIXES = (
    ("CLOUDFLARE_", "cloudflare"), ("CF_", "cloudflare"),
    ("GITHUB_", "github"), ("GH_", "github"),
    ("HCLOUD_", "hetzner"), ("HETZNER_", "hetzner"),
    ("OPENAI_", "openai"), ("ANTHROPIC_", "anthropic"), ("VERCEL_", "vercel"),
    ("GITLAB_", "gitlab"), ("AWS_", "aws"), ("DIGITALOCEAN_", "digitalocean"),
    ("STRIPE_", "stripe"), ("SENTRY_", "sentry"), ("POSTHOG_", "posthog"),
    ("COOLIFY_", "coolify"), ("HOSTINGER_", "hostinger"), ("BACKBLAZE_", "backblaze"),
)
KIND_SUFFIXES = (
    ("_API_TOKEN", "api_token"), ("_ACCESS_TOKEN", "access_token"), ("_API_KEY", "api_key"),
    ("_ACCOUNT_ID", "account_id"), ("_TOKEN_NAME", "token_name"), ("_TOKEN", "token"),
    ("_SECRET", "secret"), ("_PASSWORD", "password"), ("_KEY", "key"),
)


def infer(name: str) -> dict[str, Any] | None:
    """Provider, kind and account tag implied by a name; None if unrecognised."""
    match = next(((prefix, provider) for prefix, provider in PROVIDER_PREFIXES if name.startswith(prefix)), None)
    if match is None:
        return None
    prefix, provider = match
    rest = "_" + name[len(prefix):]
    suffix, kind = next(((suffix, kind) for suffix, kind in KIND_SUFFIXES if rest.endswith(suffix)), ("", None))
    middle = rest[: -len(suffix)].strip("_") if suffix else ""
    tag = middle.split("_")[0].lower() if middle else None
    return {"provider": provider, "kind": kind, "tag": tag, "evidence": f"name prefix {prefix}"}


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:40] or "account"


def draft_for(data: dict[str, Any], name: str) -> dict[str, Any] | None:
    """A draft record for an undescribed stored secret."""
    guess = infer(name)
    if guess is None:
        return None
    draft = {"name": name, "provider": guess["provider"], "kind": guess["kind"], "confirmed": False,
             "evidence": guess["evidence"]}
    if name == DEFAULT_ENV.get(guess["provider"]):
        draft["note"] = "bare conventional variable stored directly; it is used as-is; record its account"
        return draft
    tag = guess["tag"]
    ref = f"{guess['provider']}-{tag}" if tag else ""
    account = (data.get("provider_accounts") or {}).get(ref)
    if account and account.get("provider") == guess["provider"]:
        draft["account_ref"] = ref
        draft["evidence"] += f"; account tag {tag.upper()} matches account {ref}"
    elif tag:
        draft["account_hint"] = tag.upper()
    return draft
