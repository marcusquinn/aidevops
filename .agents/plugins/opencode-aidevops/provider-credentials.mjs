// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// OpenCode lists every provider named in config as connected. The config hook
// always adds OpenAI model metadata, so `openai` appears connected with
// `source: "config"` even when no credential exists, and a routed child then
// fails with "OpenAI API key is missing" (GH#35762). Env, auth.json and OAuth
// loaders set `key` or `options.apiKey`; custom endpoints set `baseURL`,
// `headers` or `fetch`. Providers without `source` (older servers) are trusted.

const CREDENTIAL_OPTION_KEYS = ["apiKey", "baseURL", "headers", "fetch"];

function hasValue(value) {
  if (value && typeof value === "object") return Object.keys(value).length > 0;
  return Boolean(value);
}

/** True when provider options carry a key or a custom endpoint/transport. */
export function optionsHaveCredentials(options) {
  return CREDENTIAL_OPTION_KEYS.some((key) => hasValue(options?.[key]));
}

export function providerHasUsableCredentials(provider) {
  if (provider?.source !== "config") return true;
  return hasValue(provider.key) || optionsHaveCredentials(provider.options);
}
