// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  directFileMutations,
  expectedSimpleMutationContent,
  isDirectFileMutationTool,
} from "./quality-hooks-git-safety.mjs";
import {
  applyApprovedMutationPatch,
  renderApprovedSourceContent,
} from "./source-access-manifest-approval.mjs";

export { ROOT_BROKER, applyApprovedRead, brokerMatchesCurrentRelease,
  checkGateWithApprovalInstructions, requestApprovalId } from "./source-access-guidance.mjs";

function provenanceKey(sessionId, filePath) {
  return `${sessionId}\0${resolve(filePath)}`;
}

function operationKey(sessionId, callId) {
  return `${sessionId}\0${callId}`;
}

function sameIdentity(candidate, state) {
  return Boolean(candidate) && candidate.repoRoot === state.repoRoot &&
    candidate.relativePath === state.relativePath;
}

function sameFileIdentity(left, right) {
  return Boolean(left && right) && left.device === right.device && left.inode === right.inode;
}

function completeMutationMatches(approval, snapshot, state, entry) {
  return sameIdentity(approval, state) && sameIdentity(snapshot, state) &&
    snapshot.contentSha256 === entry.expectedSha256 && snapshot.content.equals(entry.expectedContent);
}

function expectedApprovedMutationContent(state, mutation) {
  const simple = expectedSimpleMutationContent(state, mutation);
  return simple === undefined ? applyApprovedMutationPatch(state, mutation) : simple;
}

class MutationProvenance {
  constructor(options) {
    Object.assign(this, options);
    this.approvals = new Map();
    this.pendingMutations = new Map();
    this.pendingReads = new Map();
    this.denialReasons = new Map();
  }

  invalidate(key, reason) {
    this.approvals.delete(key);
    this.denialReasons.set(key, reason);
  }

  revalidate(state, sessionId, filePath, reason, sourceContext) {
    if (this.now() >= state.expiresAt) return { denial: "expired" };
    let approval = false;
    try {
      approval = this.verify({
        sessionId, filePath, reason, repositoryDir: this.repositoryDir,
        authorizedApprovalId: state.approvalId,
        sourceContext,
      });
    } catch {
      return { denial: "invalid" };
    }
    if (!sameIdentity(approval, state)) return { denial: "invalid" };
    const snapshot = this.snapshot(filePath, this.git, this.gitRun);
    if (!sameIdentity(snapshot, state) || snapshot.contentSha256 !== state.contentSha256
      || !sameFileIdentity(snapshot.fileIdentity, state.fileIdentity)) {
      return { denial: "drift" };
    }
    return { approval, snapshot };
  }

  rememberApproval({ sessionId, filePath, approval }) {
    const fields = ["approvalId", "canonicalPath", "contentSha256", "expiresAt", "repoRoot", "relativePath"];
    if (!fields.every((field) => approval?.[field])) return;
    try {
      const content = readFileSync(approval.approvedPath);
      if (createHash("sha256").update(content).digest("hex") !== approval.contentSha256) return;
      const snapshot = this.snapshot(filePath, this.git, this.gitRun);
      if (!sameIdentity(snapshot, approval) || snapshot.contentSha256 !== approval.contentSha256) return;
      if (approval.fileIdentity && !sameFileIdentity(approval.fileIdentity, snapshot.fileIdentity)) return;
      this.approvals.set(provenanceKey(sessionId, filePath), { ...approval, content, fileIdentity: snapshot.fileIdentity });
      this.denialReasons.delete(provenanceKey(sessionId, filePath));
    } catch {
      // The initial root-owned snapshot remains mandatory; never cache an unreadable path.
    }
  }

  authorizeRead({ sessionId, callId, filePath, reason, args, sourceContext }) {
    const key = provenanceKey(sessionId, filePath);
    const state = this.approvals.get(key);
    if (!state || !callId) return false;
    const result = this.revalidate(state, sessionId, filePath, reason, sourceContext);
    if (!result.approval) {
      this.invalidate(key, result.denial);
      return false;
    }
    this.pendingReads.set(operationKey(sessionId, callId), {
      args: { ...args }, content: Buffer.from(state.content),
    });
    return { ...result.approval, approvedPath: state.approvedPath };
  }

  observedReadProof({ sessionId, filePath, approvalId, repoRoot }) {
    const state = this.approvals.get(provenanceKey(sessionId, filePath));
    if (!state?.fileIdentity || state.approvalId !== approvalId || state.repoRoot !== repoRoot
      || this.now() >= state.expiresAt) return null;
    // Memory-only metadata: the CLI must independently check the signed receipt,
    // revocation, lifetime and fresh file bytes/identity. Never return source text
    // or run synchronous filesystem/signature work on the native IPC listener.
    return { schema: "aidevops-source-observed-read/v1", approval_id: state.approvalId,
      path: state.canonicalPath, content_sha256: state.contentSha256,
      file_identity: state.fileIdentity, expires_at: state.expiresAt };
  }

  finishRead(sessionId, callId, output, succeeded) {
    const key = operationKey(sessionId, callId);
    const pending = this.pendingReads.get(key);
    this.pendingReads.delete(key);
    if (!pending || !succeeded) return;
    output.output = renderApprovedSourceContent(pending.content, pending.args, output.output);
    output.metadata = { ...(output.metadata || {}), sourceAccessContinuation: true };
  }

  contextPaths(sessionId, input, output, after = false) {
    if (after) {
      return (this.pendingMutations.get(operationKey(sessionId, input.callID || "")) || [])
        .map((entry) => entry.filePath);
    }
    if (!isDirectFileMutationTool(input.tool)) return [];
    return directFileMutations(input.tool, output.args, this.repositoryDir)
      .map((entry) => entry.filePath)
      .filter((path) => this.approvals.has(provenanceKey(sessionId, path)));
  }

  beginMutation({ sessionId, callId, mutations, reason = this.reason, sourceContextForPath }) {
    if (!callId || !Array.isArray(mutations)) return;
    const entries = [];
    for (const mutation of mutations) {
      const key = provenanceKey(sessionId, mutation.filePath);
      const state = this.approvals.get(key);
      if (!state) continue;
      const result = this.revalidate(state, sessionId, mutation.filePath, reason,
        sourceContextForPath?.(mutation.filePath));
      const expectedContent = result.approval && expectedApprovedMutationContent(state, mutation);
      if (!expectedContent) {
        this.invalidate(key, result.denial || "drift");
        continue;
      }
      entries.push({
        expectedContent,
        expectedSha256: createHash("sha256").update(expectedContent).digest("hex"),
        filePath: mutation.filePath,
        key,
        state,
      });
    }
    if (entries.length > 0) this.pendingMutations.set(operationKey(sessionId, callId), entries);
  }

  finishMutation({ sessionId, callId, succeeded, reason = this.reason, sourceContextForPath }) {
    const pendingKey = operationKey(sessionId, callId);
    const entries = this.pendingMutations.get(pendingKey) || [];
    this.pendingMutations.delete(pendingKey);
    for (const entry of entries) {
      this.finishMutationEntry(entry, sessionId, reason, succeeded, sourceContextForPath?.(entry.filePath));
    }
  }

  finishMutationEntry(entry, sessionId, reason, succeeded, sourceContext) {
    if (!succeeded) {
      this.invalidate(entry.key, "drift");
      return;
    }
    let approval = false;
    try {
      approval = this.verify({
        sessionId, filePath: entry.filePath, reason, repositoryDir: this.repositoryDir,
        authorizedApprovalId: entry.state.approvalId,
        sourceContext,
      });
    } catch {
      this.invalidate(entry.key, "invalid");
      return;
    }
    const snapshot = this.snapshot(entry.filePath, this.git, this.gitRun);
    if (!completeMutationMatches(approval, snapshot, entry.state, entry)) {
      this.invalidate(entry.key, "drift");
      return;
    }
    this.approvals.set(entry.key, {
      ...entry.state, content: Buffer.from(snapshot.content), contentSha256: snapshot.contentSha256,
      fileIdentity: snapshot.fileIdentity,
    });
    this.denialReasons.delete(entry.key);
  }

  denialReason(sessionId, filePath) {
    return this.denialReasons.get(provenanceKey(sessionId, filePath)) || "missing";
  }
}

export function createMutationProvenance(options) {
  return new MutationProvenance(options);
}

export function observedToolSucceeded(output, classify) {
  if (!output || typeof output !== "object") return false;
  const hasOutcome = typeof output.output === "string" || (output.metadata && typeof output.metadata === "object");
  return hasOutcome && classify(output);
}

export function beginObservedSourceMutation(context, input, output) {
  if (!isDirectFileMutationTool(input.tool)) return;
  context.sourceAccessProvenance.beginMutation({
    sessionId: context.sessionId,
    callId: input.callID || "",
    mutations: directFileMutations(input.tool, output.args, context.repositoryDir),
    reason: context.sourceAccessReason,
    sourceContextForPath: context.sourceContextForPath,
  });
}

export function finishObservedSourceAccess(context, input, output, classify) {
  const callId = input.callID || "";
  const succeeded = observedToolSucceeded(output, classify);
  context.sourceAccessProvenance.finishRead(context.sessionId, callId, output, succeeded);
  if (!isDirectFileMutationTool(input.tool)) return;
  context.sourceAccessProvenance.finishMutation({
    sessionId: context.sessionId,
    callId,
    succeeded,
    reason: context.sourceAccessReason,
    sourceContextForPath: context.sourceContextForPath,
  });
}
