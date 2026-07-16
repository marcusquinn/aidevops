// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";

export function isObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

export function clampInteger(value, minimum, maximum, fallback) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) return fallback;
  return Math.min(maximum, Math.max(minimum, parsed));
}

export function canonicalTimestamp(value, fallback = "") {
  if (typeof value !== "string" || !value) return fallback;
  const epoch = Date.parse(value);
  return Number.isFinite(epoch) ? new Date(epoch).toISOString() : fallback;
}

export function compareAscii(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function serializePrimitive(value) {
  if (value === null) return "null";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : "null";
  if (typeof value === "bigint") throw new TypeError("Do not know how to serialize a BigInt");
  return undefined;
}

function serializeArray(value) {
  const items = Array.from(value, (item) => stableSerialize(item) ?? "null");
  return `[${items.join(",")}]`;
}

function serializeObject(value) {
  const properties = [];
  for (const key of Object.keys(value).sort()) {
    const serialized = stableSerialize(value[key]);
    if (serialized !== undefined) properties.push(`${JSON.stringify(key)}:${serialized}`);
  }
  return `{${properties.join(",")}}`;
}

function stableSerialize(value) {
  if (Array.isArray(value)) return serializeArray(value);
  if (isObject(value)) return serializeObject(value);
  return serializePrimitive(value);
}

export function hash(value, length = 64) {
  const serialized = typeof value === "string" ? value : stableSerialize(value);
  return createHash("sha256").update(serialized).digest("hex").slice(0, length);
}
