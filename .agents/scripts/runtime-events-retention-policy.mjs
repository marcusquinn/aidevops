// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Minimum runtime evidence that retention must preserve without compaction. */

const ERROR_STATUS = new Set([
  "blocked", "cancelled", "denied", "error", "failed", "rejected", "timed_out", "timeout",
]);
const PROTECTED_EVENT_TYPE = /^(audit|deploy|full-loop|objective|permission|release|security|session|subagent|worker)\.|(^|\.)(blocked|cancelled|completed|denied|error|failed|rejected|started|stopped|terminated|timeout)(\.|$)/;

function parsedPayload(row) {
  try {
    const payload = JSON.parse(row.payload_json || "{}");
    return payload && typeof payload === "object" ? payload : {};
  } catch {
    return {};
  }
}

/** True when a row belongs to the minimum terminal/error/lifecycle/security/audit envelope. */
export function isProtectedRuntimeEvent(row) {
  if (row?.state_version !== null && row?.state_version !== undefined) return true;
  const eventType = String(row?.event_type || "").toLowerCase();
  if (PROTECTED_EVENT_TYPE.test(eventType)) return true;
  const payload = parsedPayload(row);
  if (payload.success === false || payload.error_type ||
      (payload.exit_code !== undefined && Number(payload.exit_code) !== 0)) {
    return true;
  }
  return ERROR_STATUS.has(String(payload.status || "").toLowerCase());
}
