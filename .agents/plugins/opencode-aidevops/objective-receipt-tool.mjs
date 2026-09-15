// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

export function createObjectiveReceiptTool(tool, recordObjectiveDecision) {
  const z = tool.schema;
  return tool({
    description: "Record an explicit parent acceptance/repair decision and, only with matching evidence, an objective outcome. This never infers acceptance from child or host completion.",
    args: {
      parent_session_id: z.string().optional(),
      objective_id: z.string().optional(),
      run_id: z.string().optional(),
      contribution_id: z.string().optional(),
      outcome: z.enum(["accepted_unchanged", "accepted_repaired", "rejected", "reused", "unknown"]).optional(),
      repair_contribution_id: z.string().optional(),
      intervention_count: z.number().optional(),
      objective_outcome: z.enum(["verified", "accepted_unverified", "failed", "cancelled", "incomplete", "unknown"]).optional(),
      evidence_kind: z.string().optional(),
      evidence_fingerprint: z.string().optional(),
      observer: z.string().optional(),
      policy_version: z.string().optional(),
    },
    async execute(args) {
      return recordObjectiveDecision({
        parentSessionID: args.parent_session_id,
        objectiveID: args.objective_id,
        runID: args.run_id,
        contributionID: args.contribution_id,
        outcome: args.outcome,
        repairContributionID: args.repair_contribution_id,
        interventionCount: args.intervention_count,
        objectiveOutcome: args.objective_outcome,
        evidenceKind: args.evidence_kind,
        evidenceFingerprint: args.evidence_fingerprint,
        observer: args.observer,
        policyVersion: args.policy_version || "v1",
        source: "explicit_parent_decision",
      });
    },
  });
}
