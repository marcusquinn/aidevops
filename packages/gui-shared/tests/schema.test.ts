import { describe, expect, test } from "bun:test";
import {
  createEnvelope,
  FILE_EXPLORER_ROUTE_MANIFEST,
  GUI_FILE_ROOTS,
  conversationHasScope,
  isReadOnlyManifest,
  participantCanReadConversation,
  PULSE_WORKERS_ACTION_ROUTE_MANIFEST,
  PULSE_WORKERS_ACTION_STATUS_ROUTE_MANIFEST,
  sortConversationMessageParts,
  sortConversationMessages,
  STATUS_ROUTE_MANIFEST,
  TAMBO_COMPONENT_SCHEMAS,
  TAMBO_PROXY_ROUTE_MANIFEST,
  statusFixture,
  validateTamboComponentPayload,
  VAULT_STATUS_ROUTE_MANIFEST,
  type GuiConversationThread,
} from "../src";

describe("GUI shared schema contracts", () => {
  test("status route is declared as a read-only operation", () => {
    expect(isReadOnlyManifest(STATUS_ROUTE_MANIFEST)).toBe(true);
    expect(STATUS_ROUTE_MANIFEST.command_pattern).toEqual(["aidevops", "status"]);
  });

  test("file explorer route is read-only and root allowlisted", () => {
    expect(isReadOnlyManifest(FILE_EXPLORER_ROUTE_MANIFEST)).toBe(true);
    expect(FILE_EXPLORER_ROUTE_MANIFEST.operation_id).toBe("filesystem.read");
    expect(GUI_FILE_ROOTS.map((root) => root.id)).toEqual(["agents", "config", "localSetup", "git"]);
  });

  test("vault route is metadata-only and read-only", () => {
    expect(isReadOnlyManifest(VAULT_STATUS_ROUTE_MANIFEST)).toBe(true);
    expect(VAULT_STATUS_ROUTE_MANIFEST.operation_id).toBe("vault.status.read");
    expect(VAULT_STATUS_ROUTE_MANIFEST.redactions).toContain("vault_passphrases");
  });

  test("Tambo route and registered component schemas are strict and read-safe", () => {
    expect(isReadOnlyManifest(TAMBO_PROXY_ROUTE_MANIFEST)).toBe(true);
    expect(TAMBO_PROXY_ROUTE_MANIFEST.redactions).toContain("tambo_api_keys");
    expect(TAMBO_COMPONENT_SCHEMAS.map((schema) => schema.name)).toEqual(["TaskCard", "PullRequestCard", "CICheckSummary", "WorkerStatusCard", "DeploymentStatusCard", "RepoHealthCard", "ApprovalPromptCard"]);
    expect(TAMBO_COMPONENT_SCHEMAS.every((schema) => schema.additionalProperties === false)).toBe(true);
  });

  test("Pulse and Workers action routes declare allowlisted command boundaries", () => {
    expect(PULSE_WORKERS_ACTION_ROUTE_MANIFEST.operation_id).toBe("pulse_workers.action.run");
    expect(PULSE_WORKERS_ACTION_ROUTE_MANIFEST.classification).toBe("write");
    expect(PULSE_WORKERS_ACTION_ROUTE_MANIFEST.command_pattern).toContain("allowlisted");
    expect(PULSE_WORKERS_ACTION_ROUTE_MANIFEST.redactions).toContain("authorization_headers");
    expect(isReadOnlyManifest(PULSE_WORKERS_ACTION_STATUS_ROUTE_MANIFEST)).toBe(true);
  });

  test("Tambo payload validation enforces tenant scope and strict props", () => {
    const scope = { tenant_ref: "tenant:local-owner", workspace_ref: "workspace:aidevops", repo_ref: "repo:marcusquinn/aidevops" };
    const valid = validateTamboComponentPayload({ component: "TaskCard", tenant_ref: "tenant:local-owner", session_ref: "conversation:ai-session-1", read_only: true, props: { title: "Implement Tambo", status: "in review", reference: "#25713" } }, scope);
    const wrongTenant = validateTamboComponentPayload({ component: "TaskCard", tenant_ref: "tenant:other", session_ref: "conversation:ai-session-1", read_only: true, props: { title: "Implement Tambo", status: "in review" } }, scope);
    const extraProp = validateTamboComponentPayload({ component: "TaskCard", tenant_ref: "tenant:local-owner", session_ref: "conversation:ai-session-1", read_only: true, props: { title: "Implement Tambo", status: "in review", href: "not-allowed" } }, scope);
    const activeApproval = validateTamboComponentPayload({ component: "ApprovalPromptCard", tenant_ref: "tenant:local-owner", session_ref: "conversation:ai-session-1", read_only: true, props: { action: "Merge", reason: "Checks passed", risk: "high", disabled: false } }, scope);

    expect(valid.ok).toBe(true);
    expect(wrongTenant.errors).toContain("tenant_scope_mismatch");
    expect(extraProp.errors).toContain("unexpected_prop:href");
    expect(activeApproval.errors).toContain("approval_prompt_must_be_disabled");
  });

  test("Tambo payload validation reports malformed envelopes before props", () => {
    const scope = { tenant_ref: "tenant:local-owner", workspace_ref: "workspace:aidevops", repo_ref: "repo:marcusquinn/aidevops" };

    expect(validateTamboComponentPayload(null, scope).errors).toEqual(["payload_not_object"]);
    expect(validateTamboComponentPayload({ props: {} }, scope).errors).toEqual(["component_missing"]);
    expect(validateTamboComponentPayload({ component: "UnknownCard", props: {} }, scope).errors).toEqual(["component_not_registered"]);
    expect(validateTamboComponentPayload({ component: "TaskCard", tenant_ref: "tenant:local-owner", session_ref: "conversation:ai-session-1", read_only: true, props: [] }, scope).errors).toEqual(["props_not_object"]);
  });

  test("status envelope preserves source and redaction metadata", () => {
    const envelope = createEnvelope({
      operation_id: "setup.status.read",
      source: {
        surface: "setup",
        authority: "aidevops helpers",
        path_refs: ["~/.config/aidevops/settings.json"],
      },
      data: statusFixture,
      observed_at: "2026-06-21T00:00:00.000Z",
    });

    expect(envelope.ok).toBe(true);
    expect(envelope.operation_id).toBe("setup.status.read");
    expect(envelope.redactions).toContain("secret_values");
    expect(envelope.data.runtime.read_only).toBe(true);
    expect(envelope.data.machine.initials).toBe("LM");
    expect(envelope.data.update.restart_required).toBe(false);
    expect(envelope.data.navigation.map((item) => item.label)).toContain("Config");
    expect(envelope.data.settings.value_policy).toBe("keys_only_no_values");
    expect(envelope.data.local_repos.path_ref).toBe("~/Git");
    expect(envelope.data.oauth_pool.value_policy).toBe("metadata_only_no_tokens");
    expect(envelope.data.vault.value_policy).toBe("metadata_only_no_secret_material");
    expect(envelope.data.pulse_workers.value_policy).toBe("metadata_only_no_prompt_payloads_no_secrets");
    expect(envelope.data.pulse_workers.kpis.every((kpi) => kpi.period_label.length > 0 && kpi.scope_label.length > 0 && kpi.comparison_label.length > 0)).toBe(true);
    expect(envelope.data.pulse_workers.events[0].usage?.provider).toBe("openai");
    expect(envelope.data.pulse_workers.events[0].usage?.cached_tokens).toBeGreaterThan(0);
    expect(envelope.data.pulse_workers.events[2].issue_origin).toBe("third_party");
    expect(envelope.data.pulse_workers.events[2].author_association).toBe("CONTRIBUTOR");
    expect(envelope.data.pulse_workers.insights.map((finding) => finding.kind)).toEqual(["third_party_waiting", "weak_verification", "resource_pressure"]);
    expect(envelope.data.pulse_workers.insights.every((finding) => finding.primary_action === "create_systemic_fix" && finding.period_label.length > 0 && finding.scope_label.length > 0)).toBe(true);
    expect(envelope.data.pulse_workers.charts.map((chart) => chart.points[0]?.period)).toEqual(["day", "week", "month", "year"]);
    expect(envelope.data.pulse_workers.actions.map((action) => action.id)).toEqual(["diagnose", "run_pulse", "open_logs", "create_systemic_fix"]);
    expect(envelope.data.pulse_workers.actions.filter((action) => action.classification === "write").every((action) => action.confirmation === "required")).toBe(true);
    expect(envelope.data.vault.collections.map((collection) => collection.surface_ids).flat()).toContain("agents");
    expect(envelope.data.setup_targets[0].path_ref).toBe("~/.aidevops/agents/VERSION");
    expect(envelope.data.ai_apps.map((app) => app.name)).toContain("OpenCode");
    expect(envelope.data.capabilities[0].status).toBe("available");
  });

  test("conversation thread model preserves tenant scope and active membership", () => {
    const thread = conversationThreadFixture();

    expect(conversationHasScope(thread, {
      tenant_ref: "tenant:local-owner",
      workspace_ref: "workspace:aidevops",
      repo_ref: "repo:marcusquinn/aidevops",
    })).toBe(true);
    expect(conversationHasScope(thread, {
      tenant_ref: "tenant:other",
      workspace_ref: "workspace:aidevops",
      repo_ref: "repo:marcusquinn/aidevops",
    })).toBe(false);
    expect(participantCanReadConversation(thread, "participant:human-owner")).toBe(true);
    expect(participantCanReadConversation(thread, "participant:removed-user")).toBe(false);
  });

  test("conversation messages and parts keep deterministic ordering", () => {
    const thread = conversationThreadFixture();
    const orderedMessages = sortConversationMessages(thread.messages);
    const orderedParts = sortConversationMessageParts(thread.parts.filter((part) => part.message_id === "message:assistant-1"));

    expect(orderedMessages.map((message) => message.id)).toEqual(["message:user-1", "message:assistant-1"]);
    expect(orderedParts.map((part) => part.kind)).toEqual(["text", "tool_call", "tambo_component"]);
    expect(orderedParts[2].payload_json).toEqual({ component: "ReleaseReadinessCard", status: "planned" });
    expect(orderedMessages[1].usage?.total_tokens).toBe(168);
  });
});

function conversationThreadFixture(): GuiConversationThread {
  return {
    conversation: {
      id: "conversation:ai-session-1",
      type: "ai_session",
      title: "Plan AI collaboration workspace",
      scope: {
        tenant_ref: "tenant:local-owner",
        workspace_ref: "workspace:aidevops",
        repo_ref: "repo:marcusquinn/aidevops",
      },
      source_ref: "opencode:session:metadata-only",
      status: "active",
      created_at: "2026-06-27T18:00:00.000Z",
      updated_at: "2026-06-27T18:01:00.000Z",
    },
    participants: [
      {
        id: "participant:human-owner",
        conversation_id: "conversation:ai-session-1",
        kind: "human",
        display_name: "Local owner",
        identity_ref: "identity:owner",
        agent_ref: null,
        worker_ref: null,
        membership_state: "active",
        joined_at: "2026-06-27T18:00:00.000Z",
      },
      {
        id: "participant:assistant",
        conversation_id: "conversation:ai-session-1",
        kind: "ai_assistant",
        display_name: "AI DevOps",
        identity_ref: null,
        agent_ref: "agent:build-plus",
        worker_ref: null,
        membership_state: "active",
        joined_at: "2026-06-27T18:00:00.000Z",
      },
      {
        id: "participant:removed-user",
        conversation_id: "conversation:ai-session-1",
        kind: "human",
        display_name: "Former member",
        identity_ref: "identity:former",
        agent_ref: null,
        worker_ref: null,
        membership_state: "removed",
        joined_at: "2026-06-27T18:00:00.000Z",
      },
    ],
    messages: [
      {
        id: "message:assistant-1",
        conversation_id: "conversation:ai-session-1",
        sender_participant_id: "participant:assistant",
        sender_kind: "ai_assistant",
        sequence: 2,
        status: "sent",
        usage: {
          provider_ref: "provider:anthropic",
          model_ref: "model:claude-sonnet",
          input_tokens: 120,
          output_tokens: 48,
          total_tokens: 168,
          cost_ref: null,
        },
        created_at: "2026-06-27T18:01:00.000Z",
        edited_at: null,
      },
      {
        id: "message:user-1",
        conversation_id: "conversation:ai-session-1",
        sender_participant_id: "participant:human-owner",
        sender_kind: "human",
        sequence: 1,
        status: "sent",
        usage: null,
        created_at: "2026-06-27T18:00:30.000Z",
        edited_at: null,
      },
    ],
    parts: [
      {
        id: "part:assistant-card",
        message_id: "message:assistant-1",
        kind: "tambo_component",
        ordinal: 3,
        text: null,
        payload_json: { component: "ReleaseReadinessCard", status: "planned" },
        file_ref: null,
        source_ref: null,
      },
      {
        id: "part:assistant-text",
        message_id: "message:assistant-1",
        kind: "text",
        ordinal: 1,
        text: "Here is the implementation map.",
        payload_json: null,
        file_ref: null,
        source_ref: null,
      },
      {
        id: "part:assistant-tool",
        message_id: "message:assistant-1",
        kind: "tool_call",
        ordinal: 2,
        text: null,
        payload_json: { helper: "git ls-files", result: "ok" },
        file_ref: null,
        source_ref: "docs/architecture/ai-collaboration-workspace.md",
      },
      {
        id: "part:user-text",
        message_id: "message:user-1",
        kind: "text",
        ordinal: 1,
        text: "Map the conversation model.",
        payload_json: null,
        file_ref: null,
        source_ref: null,
      },
    ],
    reactions: [
      {
        id: "reaction:ack",
        message_id: "message:assistant-1",
        participant_id: "participant:human-owner",
        reaction: "ack",
        created_at: "2026-06-27T18:02:00.000Z",
      },
    ],
    read_states: [
      {
        conversation_id: "conversation:ai-session-1",
        participant_id: "participant:human-owner",
        last_read_message_id: "message:assistant-1",
        last_read_sequence: 2,
        updated_at: "2026-06-27T18:02:00.000Z",
      },
    ],
  };
}
