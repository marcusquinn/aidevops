// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { basename } from "node:path";

function addRepoIdentifiers(repo, values) {
  if (!repo || typeof repo !== "object") return;
  if (typeof repo.slug === "string" && /^[^/\s]+\/[^/\s]+$/.test(repo.slug)) {
    for (const value of [repo.slug, ...repo.slug.split("/")]) values.add(value);
  }
  if (typeof repo.path === "string" && repo.path) {
    const name = basename(repo.path);
    if (name && name !== "." && name !== "..") values.add(name);
  }
}

/** Exact operator-registered identifiers, mirrored by redaction-digest-registry.py. */
export function parsePublicRepoIdentifiers(text) {
  const values = new Set();
  try {
    const repos = JSON.parse(text).initialized_repos;
    for (const repo of Array.isArray(repos) ? repos : []) addRepoIdentifiers(repo, values);
  } catch {
    // Missing or malformed configuration grants no exemptions.
  }
  return values;
}
