import type { ReactElement } from "react";
import { FiFileText, FiHash, FiPaperclip, FiTerminal } from "react-icons/fi";
import type { GuiStatusData } from "../../gui-shared/src";
import { text } from "./app-model";
import { TamboConversationPart } from "./GenUiCards";

const sessionActions = ["New", "Rename", "Pin", "Archive", "Delete", "Share", "Export"] as const;

export function sessionForRepo(status: GuiStatusData, repoPathRef: string, selectedSessionId: string | undefined) {
  const sessions = status.opencode_sessions?.sessions ?? [];
  return sessions.find((session) => session.id_ref === selectedSessionId && session.repo_path_ref === repoPathRef) ?? sessions.find((session) => session.repo_path_ref === repoPathRef);
}

export function AiSessionsSurface({ selectedRepoIndex, selectedSessionId, status }: { selectedRepoIndex: number; selectedSessionId?: string; status: GuiStatusData }): ReactElement {
  const selectedRepo = status.local_repos?.repos?.[selectedRepoIndex] ?? status.local_repos?.repos?.[0];
  const selectedSession = selectedRepo === undefined ? undefined : sessionForRepo(status, selectedRepo.path_ref, selectedSessionId);
  const providerOptions = status.oauth_pool?.providers?.filter((provider) => provider.configured || provider.total > 0) ?? [];
  const sessionTitle = selectedSession?.title ?? "AI session bridge";
  const sessionMeta = selectedSession ? `${selectedSession.model} via ${selectedSession.agent}` : "No OpenCode session metadata selected";

  return (
    <section className="chat-surface ai-sessions-surface" aria-label={text.aiSessions} data-tour="ai-sessions-surface">
      <aside className="chat-thread-panel" aria-label="AI session controls" data-tour="ai-session-list">
        <header className="chat-thread-header">
          <div>
            <p className="eyebrow">{text.aiSessions}</p>
            <h2><FiTerminal aria-hidden="true" /> {selectedRepo?.name ?? "Local workspace"}</h2>
          </div>
          <span className="count-pill">{text.readOnly}</span>
        </header>
        <div className="notice compact-notice">New, rename, pin, archive, delete, share, and export are visible but disabled until audited AI session write routes land.</div>
        <div className="sidebar-history-controls">
          {sessionActions.map((action) => <button disabled key={action} title={`${action} needs the AI session write adapter`} type="button">{action}</button>)}
        </div>
        <label className="settings-form">
          <span>Model/provider</span>
          <select
            disabled
            defaultValue={providerOptions[0]?.provider ?? "local"}
            title="Model switching needs the Turbostarter AI transport adapter."
          >
            {providerOptions.length === 0 ? (
              <option value="local">Provider setup required</option>
            ) : (
              providerOptions.map((provider) => (
                <option key={provider.provider} value={provider.provider}>
                  {provider.provider} ({provider.available}/{provider.total})
                </option>
              ))
            )}
          </select>
        </label>
      </aside>
      <div className="chat-thread-panel" data-tour="ai-session-transcript">
        <header className="chat-thread-header">
          <div>
            <p className="eyebrow">{sessionMeta}</p>
            <h2><FiHash aria-hidden="true" /> {sessionTitle}</h2>
          </div>
          <button disabled title="Convert to worker task needs dispatch backend support" type="button">Create worker task</button>
        </header>
        <div className="chat-message-list" data-tour="message-scroller">
          <MessageMarker label="Session status" detail="MessageScroller-compatible transcript; auto-scroll must pause when the reader scrolls away from the latest message." />
          <ChatBubble
            speaker="assistant"
            title={sessionTitle}
            body={
              selectedSession
                ? `Most recent OpenCode session metadata: ${sessionMeta}, updated ${selectedSession.updated_at}. Message payloads stay out of the status API until the Turbostarter AI chat bridge lands.`
                : "OpenCode session creation and continuation need an audited write route. This surface is ready for the Turbostarter AI adapter once connected."
            }
          />
          <AttachmentCard label="Context attachment" detail={selectedRepo ? `Selected repo context: ${selectedRepo.path_ref}` : "No local repos were discovered yet."} />
          <MessageMarker label="Reasoning" detail="Reasoning disclosure, tool status, sources, retries, errors, and token usage render here when the AI transport supplies those parts." />
          <ToolStatusCard />
          <TamboConversationPart
            part={{ id: "ai-session-tambo-preview", message_id: "ai-session-preview", kind: "tambo_component", ordinal: 1, text: null, payload_json: { component: "RepoHealthCard", tenant_ref: "local", session_ref: selectedSession?.id_ref ?? "ai-session-preview", read_only: true, props: { repo: selectedRepo?.name ?? "local workspace", status: "ready for Tambo cards", open_prs: 0, failing_checks: 0, notes: ["Server-proxied provider metadata", "Read-only schemas first"] } }, file_ref: null, source_ref: "tambo:ai-session-preview" }}
            scope={{ tenant_ref: "local", workspace_ref: "aidevops", repo_ref: selectedRepo?.path_ref ?? null }}
          />
        </div>
        <form className="chat-composer ai-composer" aria-label="AI prompt composer" data-tour="ai-composer">
          <button disabled title="Attachments need the audited upload/context adapter" type="button"><FiPaperclip aria-hidden="true" /> Attach</button>
          <textarea disabled placeholder={text.chatInputPlaceholder} />
          <button disabled title="Sending needs the Turbostarter AI transport adapter" type="button">Send</button>
        </form>
      </div>
    </section>
  );
}

function MessageMarker({ detail, label }: { detail: string; label: string }) {
  return <article className="chat-bubble assistant"><strong>{label}</strong><p>{detail}</p></article>;
}

function AttachmentCard({ detail, label }: { detail: string; label: string }) {
  return <article className="chat-bubble user"><strong><FiFileText aria-hidden="true" /> {label}</strong><p>{detail}</p></article>;
}

function ToolStatusCard() {
  return <article className="chat-bubble assistant"><strong>Tool status</strong><p>Tool calls, source citations, retries, errors, and usage metadata are reserved for the shared conversation part model.</p></article>;
}

function ChatBubble({ body, speaker, title }: { body: string; speaker: "assistant" | "user"; title: string }) {
  return (
    <article className={`chat-bubble ${speaker}`}>
      <strong>{title}</strong>
      <p>{body}</p>
    </article>
  );
}
