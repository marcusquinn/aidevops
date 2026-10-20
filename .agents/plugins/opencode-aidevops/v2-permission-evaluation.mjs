// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

/**
 * V2 fires `permission/evaluate` for every non-denied decision with the host's
 * computed effect ("allow" or "ask"). Only "ask" maps to V1 `permission.ask`;
 * brokering host "allow" denied every headless tool call (GH#35170). Credential
 * reads and worker write fencing stay enforced in `tool.execute.before`.
 */
export function applyV2PermissionEvaluation(permissionBroker, event) {
  if (event?.effect !== "ask") return;
  const output = { status: "ask" };
  permissionBroker.permissionAsk({
    ...event,
    type: event.action,
    patterns: event.resources,
  }, output);
  if (output.status === "allow") event.effect = "allow";
  if (output.status === "deny") event.effect = "deny";
}
