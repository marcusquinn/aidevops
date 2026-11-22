// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
import { asksFilingPermission, capMap } from "./session-continuation-utils.mjs";

const FILING_STEERING = "Your closeout asks permission to file an issue, task or TODO. Filing is already authorised: file it now under the capture rule in Framework Rules (deduplicate first) and cite the link in the body. Keep the ask only when the need itself is undecided, and then ask about the need.";

// GH#37979: filing a follow-up on a managed repository is already delegated
// (Framework Rules), so a closeout that only asks permission to file gets one
// steer per session scope to file it and report the link.
export function correctFilingPermissionAsk(state, scope, output, queue) {
  if (state.filingSteered.has(scope) || !asksFilingPermission(output?.text)) return { corrected: false };
  queue("filing", FILING_STEERING);
  return { corrected: true, filing: true };
}

// The allowance is consumed only once the steering was actually delivered.
export function markFilingDelivered(state, scope) {
  state.filingSteered.add(scope);
  capMap(state.filingSteered, state.maxScopes);
}
