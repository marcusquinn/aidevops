import type { GuiConversationThread } from "../../gui-shared/src";

export const conversationThreads: GuiConversationThread[] = [
  {
    conversation: { id: "channel-general", type: "channel", title: "general", scope: { tenant_ref: "local", workspace_ref: "aidevops", repo_ref: null }, source_ref: "seed:channels/general", status: "read_only", created_at: "2026-06-27T00:00:00Z", updated_at: "2026-06-27T12:20:00Z" },
    participants: [
      { id: "participant-local", conversation_id: "channel-general", kind: "human", display_name: "Local user", identity_ref: "local:user", agent_ref: null, worker_ref: null, membership_state: "active", joined_at: "2026-06-27T00:00:00Z" },
      { id: "participant-ai", conversation_id: "channel-general", kind: "ai_assistant", display_name: "AI DevOps", identity_ref: null, agent_ref: "aidevops", worker_ref: null, membership_state: "active", joined_at: "2026-06-27T00:00:00Z" },
      { id: "participant-system", conversation_id: "channel-general", kind: "system_bot", display_name: "System", identity_ref: null, agent_ref: null, worker_ref: null, membership_state: "active", joined_at: "2026-06-27T00:00:00Z" },
    ],
    messages: [
      { id: "message-general-1", conversation_id: "channel-general", sender_participant_id: "participant-system", sender_kind: "system", sequence: 1, status: "sent", usage: null, created_at: "2026-06-27T12:00:00Z", edited_at: null },
      { id: "message-general-2", conversation_id: "channel-general", sender_participant_id: "participant-ai", sender_kind: "ai_assistant", sequence: 2, status: "delivered", usage: { provider_ref: "local", model_ref: "workflow-summary", input_tokens: 0, output_tokens: 0, total_tokens: 0, cost_ref: null }, created_at: "2026-06-27T12:15:00Z", edited_at: null },
    ],
    parts: [
      { id: "part-general-1", message_id: "message-general-1", kind: "event_marker", ordinal: 1, text: "#general is ready for repo, deployment, review, and incident coordination.", payload_json: null, file_ref: null, source_ref: "seed" },
      { id: "part-general-2", message_id: "message-general-2", kind: "text", ordinal: 1, text: "Mention @AI DevOps or a worker to turn a thread into an audited task once write routes land.", payload_json: null, file_ref: null, source_ref: null },
    ],
    reactions: [{ id: "reaction-general-1", message_id: "message-general-2", participant_id: "participant-local", reaction: "ack", created_at: "2026-06-27T12:16:00Z" }],
    read_states: [{ conversation_id: "channel-general", participant_id: "participant-local", last_read_message_id: "message-general-1", last_read_sequence: 1, updated_at: "2026-06-27T12:10:00Z" }],
  },
  {
    conversation: { id: "channel-workers", type: "channel", title: "worker-feed", scope: { tenant_ref: "local", workspace_ref: "aidevops", repo_ref: "current" }, source_ref: "seed:channels/worker-feed", status: "read_only", created_at: "2026-06-27T00:00:00Z", updated_at: "2026-06-27T12:30:00Z" },
    participants: [{ id: "participant-worker", conversation_id: "channel-workers", kind: "worker", display_name: "Worker queue", identity_ref: null, agent_ref: null, worker_ref: "workers", membership_state: "active", joined_at: "2026-06-27T00:00:00Z" }],
    messages: [{ id: "message-workers-1", conversation_id: "channel-workers", sender_participant_id: "participant-worker", sender_kind: "worker", sequence: 1, status: "delivered", usage: null, created_at: "2026-06-27T12:30:00Z", edited_at: null }],
    parts: [{ id: "part-workers-1", message_id: "message-workers-1", kind: "event_marker", ordinal: 1, text: "Worker events for reviews, deployments, incidents, and releases collect here.", payload_json: null, file_ref: null, source_ref: "seed" }],
    reactions: [],
    read_states: [{ conversation_id: "channel-workers", participant_id: "participant-local", last_read_message_id: null, last_read_sequence: 0, updated_at: "2026-06-27T12:00:00Z" }],
  },
  {
    conversation: { id: "dm-ai-devops", type: "dm", title: "AI DevOps", scope: { tenant_ref: "local", workspace_ref: "aidevops", repo_ref: null }, source_ref: "seed:dms/ai-devops", status: "read_only", created_at: "2026-06-27T00:00:00Z", updated_at: "2026-06-27T12:40:00Z" },
    participants: [{ id: "participant-dm-local", conversation_id: "dm-ai-devops", kind: "human", display_name: "Local user", identity_ref: "local:user", agent_ref: null, worker_ref: null, membership_state: "active", joined_at: "2026-06-27T00:00:00Z" }, { id: "participant-dm-ai", conversation_id: "dm-ai-devops", kind: "ai_assistant", display_name: "AI DevOps", identity_ref: null, agent_ref: "aidevops", worker_ref: null, membership_state: "active", joined_at: "2026-06-27T00:00:00Z" }],
    messages: [{ id: "message-dm-1", conversation_id: "dm-ai-devops", sender_participant_id: "participant-dm-ai", sender_kind: "ai_assistant", sequence: 1, status: "delivered", usage: null, created_at: "2026-06-27T12:40:00Z", edited_at: null }],
    parts: [{ id: "part-dm-1", message_id: "message-dm-1", kind: "text", ordinal: 1, text: "Direct support threads share the same message parts, participants, reactions, and read state as channels.", payload_json: null, file_ref: null, source_ref: null }],
    reactions: [],
    read_states: [{ conversation_id: "dm-ai-devops", participant_id: "participant-dm-local", last_read_message_id: null, last_read_sequence: 0, updated_at: "2026-06-27T12:00:00Z" }],
  },
];
