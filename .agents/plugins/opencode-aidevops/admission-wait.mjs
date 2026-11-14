// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Writer contention is the only retried admission refusal (GH#38158). The
// reason token is the safe protocol reason admitToolOwner embeds in its message.
const CONTENTION_REFUSAL = /\(database-locked\)/;
const CONTENTION_WAIT_SECONDS = 30;
const CONTENTION_PAUSE_MS = Object.freeze({ first: 500, maximum: 4000 });

/** Same bound and variable as worker launch admission; invalid values deny. */
export function contentionWaitMs(value = process.env.AIDEVOPS_LIFECYCLE_ADMISSION_WAIT_SECONDS) {
  const seconds = value === undefined ? CONTENTION_WAIT_SECONDS : Number(value);
  if (String(value).trim() === "" || !Number.isFinite(seconds) || seconds < 0 || seconds > 300) return null;
  return seconds * 1000;
}

/**
 * Admit the supervisor, waiting out registry writer contention only.
 *
 * The supervisor is detached from the session, so a bounded wait here never
 * blocks the interactive runtime, unlike synchronous Bash/Edit/Write admission.
 * Each attempt is the complete idempotent admission, and each refusal is
 * recorded by admitToolOwner's existing diagnostic. Any other reason, or
 * contention past the deadline, refuses with the original error.
 */
export async function admitWithContentionWait(admit, options = {}) {
  const now = options.now || Date.now;
  const sleep = options.sleep || ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  // Measured from the first attempt, like worker launch; only an attempt already
  // in flight (its helper busy timeouts) may finish after the deadline.
  const startedAt = now();
  let deadline = null;
  let pause = CONTENTION_PAUSE_MS.first;
  for (;;) {
    try {
      return admit();
    } catch (error) {
      if (!CONTENTION_REFUSAL.test(String(error?.message || ""))) throw error;
      if (deadline === null) {
        const waitMs = contentionWaitMs(options.waitSeconds);
        if (waitMs === null) throw new Error("BLOCKED: invalid-admission-wait", { cause: error });
        deadline = startedAt + waitMs;
      }
      const remaining = deadline - now();
      if (remaining <= 0) throw error;
      await sleep(Math.min(pause, remaining));
      pause = Math.min(pause * 2, CONTENTION_PAUSE_MS.maximum);
    }
  }
}
