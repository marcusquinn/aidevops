// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";

const SAFE_ID_PATTERN = /^[A-Za-z0-9._:@#/-]+$/;
const PRIVATE_PATH_ID_PATTERN = /^(?:file:\/{2,3}|\/|[A-Za-z]:[\\/])/;
const REPOSITORY_LIKE_ID_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

function hashIdentifier(value) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

export function normaliseIdentifier(value, { required = false, fallback = "" } = {}) {
  const text = String(value ?? fallback).trim();
  if (!text) {
    if (required) throw new TypeError("runtime event identifier is required");
    return null;
  }
  if (!SAFE_ID_PATTERN.test(text) || PRIVATE_PATH_ID_PATTERN.test(text) ||
      REPOSITORY_LIKE_ID_PATTERN.test(text) || text.length > 256) {
    return hashIdentifier(text);
  }
  return text;
}

export function normaliseEventType(value) {
  const eventType = String(value || "").trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9._-]{0,127}$/.test(eventType)) {
    throw new TypeError("runtime event type must be a bounded dotted identifier");
  }
  return eventType;
}
