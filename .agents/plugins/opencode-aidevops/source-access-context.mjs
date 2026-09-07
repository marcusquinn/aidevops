// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { randomBytes } from "node:crypto";
import { isAbsolute } from "node:path";
import { isUnprivilegedSourceRuntime } from "./source-access-context-transport.mjs";
export { isUnprivilegedSourceRuntime, listenSourceContext,
  prepareSourceContextDirectory } from "./source-access-context-transport.mjs";

export const sourceContextInstanceId = randomBytes(16).toString("hex");
export const SOURCE_CONTEXT_QUERY = "aidevops-source-context-query/v1";
export const SOURCE_CONTEXT_REPLY = "aidevops-source-context-reply/v1";

function validQuery(query) {
  if (query?.schema !== SOURCE_CONTEXT_QUERY) return false;
  if (typeof query.nonce !== "string" || !/^[a-f0-9]{64}$/.test(query.nonce)) return false;
  if (typeof query.session_id !== "string" || !/^ses_[A-Za-z0-9._:-]{2,252}$/.test(query.session_id)) return false;
  if (query.source_read !== undefined && !validSourceRead(query.source_read)) return false;
  return typeof query.repo_root === "string" && isAbsolute(query.repo_root)
    && !/[\u0000-\u001f\u007f]/.test(query.repo_root);
}

function validSourceRead(request) {
  if (typeof request?.approval_id !== "string" || !/^[a-f0-9]{64}$/.test(request.approval_id)) return false;
  return typeof request.path === "string" && isAbsolute(request.path) && !/[\u0000-\u001f\u007f]/.test(request.path);
}

function availableSession(session, sessionId) {
  if (session?.id !== sessionId) return false;
  const created = session.time?.created;
  if (!Number.isSafeInteger(created) || created < 0 || session.time.archived != null) return false;
  return typeof session.directory === "string" && typeof session.projectID === "string"
    && session.projectID.length > 0 && session.projectID.length <= 256;
}

/**
 * Metadata, NOT authority. Admission additionally needs kernel peer identity,
 * the exact proposal and human consent; grant consumers must bind this runtime
 * instance. An arbitrary live PID or caller-authored JSON is not session proof.
 * Callbacks run in the unprivileged runtime, never in the root signing broker.
 */
export function createSourceContextResponder({ lookupSession, verifyOwner, sameRepository, readSourceProof = () => null }) {
  if (![lookupSession, verifyOwner, sameRepository].every((value) => typeof value === "function")) {
    throw new Error("source context requires runtime and worktree verifiers");
  }
  return async (query, signal) => {
    if (!isUnprivilegedSourceRuntime()) throw new Error("source context requires an unprivileged runtime");
    if (!validQuery(query) || signal?.aborted) throw new Error("invalid source context query");
    const session = await lookupSession(query.session_id, signal);
    if (!availableSession(session, query.session_id)) {
      throw new Error("source context session is unavailable");
    }
    if (await sameRepository(session.directory, query.repo_root, signal) !== true
      || await verifyOwner(query.repo_root, query.session_id, signal) !== true
      || signal?.aborted) {
      throw new Error("source context worktree ownership is unavailable");
    }
    return {
      schema: SOURCE_CONTEXT_REPLY, nonce: query.nonce, authority: "none",
      session_id: session.id, session_created_at: session.time.created,
      project_id: session.projectID, repo_root: query.repo_root,
      runtime_instance_id: sourceContextInstanceId, runtime_pid: process.pid,
      uid: process.getuid(),
      ...(query.source_read === undefined ? {} : { source_read: readSourceProof({ sessionId: session.id,
        repoRoot: query.repo_root, filePath: query.source_read.path, approvalId: query.source_read.approval_id }) }),
    };
  };
}
