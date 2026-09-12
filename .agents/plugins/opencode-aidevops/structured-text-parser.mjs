// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Parse complete JSON containers without treating scalars as structured output. */
function parseJsonContainer(text) {
  try {
    const value = JSON.parse(text);
    return value !== null && typeof value === "object" ? value : null;
  } catch {
    return null;
  }
}

/** Parse complete JSON or independent NDJSON records while preserving separators. */
export function parseStructuredText(value) {
  const document = parseJsonContainer(value.trim());
  if (document !== null) {
    return { value: document, stringify: (scrubbed) => JSON.stringify(scrubbed) };
  }

  const parts = value.split(/(\r?\n)/);
  const records = [];
  let recordCount = 0;
  for (let index = 0; index < parts.length; index += 2) {
    const line = parts[index];
    if (!line.trim()) {
      records.push(null);
      continue;
    }
    const record = parseJsonContainer(line);
    if (record === null) return null;
    records.push(record);
    recordCount++;
  }
  if (recordCount === 0) return null;

  return {
    value: records,
    stringify: (scrubbed) =>
      scrubbed
        .map((record, index) => {
          const line = record === null ? parts[index * 2] : JSON.stringify(record);
          return `${line}${parts[index * 2 + 1] ?? ""}`;
        })
        .join(""),
  };
}
