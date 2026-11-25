// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { join } from "node:path";
import { hasBoundedReadTarget, isWithin } from "./permission-broker-read-target.mjs";
import { resolveReal } from "./permission-broker-read-only-root.mjs";
import { isManagedToolOutputRead } from "./permission-broker-tool-output.mjs";

// Deliberately not a shell parser: only plain words and one final device
// redirection qualify. Expansion, quoting, other paths and compound commands
// retain the normal gate. The independent bash permission is never approved here.
export function runtimeRedirectionTarget(command) {
  if (typeof command !== "string") return "";
  return /^[A-Za-z0-9_.-]+(?: +[A-Za-z0-9_.-]+)* +[0-9]?(?:>>?|<) *(\/dev\/(?:null|stdin|stdout|stderr|fd\/[0-9]+)) *$/.exec(command)?.[1] || "";
}

// OpenCode may ask for a parent wildcard. Require a recorded concrete target;
// never infer it from a broad /dev/* ask or untrusted request metadata.
const RUNTIME_DEVICE = /^\/dev\/(?:null|stdin|stdout|stderr|fd\/[0-9]+)$/;

function isManagedTempRead(context, target, forbidden) {
  const root = join(context.home, ".aidevops", ".agent-workspace", "tmp");
  // A link in the managed root itself must not redefine the authorized root.
  const realRoot = join(resolveReal(context.home), ".aidevops", ".agent-workspace", "tmp");
  if (!isWithin(root, target) || resolveReal(root) !== realRoot) return false;
  const realTarget = resolveReal(target);
  if (!realTarget || forbidden.test(realTarget)) return false;
  return isWithin(realRoot, realTarget);
}

function recordedTarget(call) {
  if (call?.tool === "bash") return runtimeRedirectionTarget(call.command);
  return call?.tool === "read" ? call.target : "";
}

export function isWorkerRuntimeRead(context, raw, forbidden) {
  if ((raw?.permission || raw?.type) !== "external_directory") return false;
  const call = context.toolCalls.get(raw?.tool?.callID || raw?.callID || "");
  const target = recordedTarget(call);
  if (!hasBoundedReadTarget(raw, target, forbidden)) return false;
  if (RUNTIME_DEVICE.test(target)) return true;
  return call.tool === "read" && isManagedTempRead(context, target, forbidden);
}

// Reads allowed without a post-allow audit record.
export function isUnauditedRuntimeRead(context, raw, forbidden) {
  return isWorkerRuntimeRead(context, raw, forbidden)
    || isManagedToolOutputRead(context.toolCalls, raw, context.dataHome);
}
