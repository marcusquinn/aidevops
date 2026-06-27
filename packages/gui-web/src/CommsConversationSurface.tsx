import { FiAtSign, FiHash, FiMessageSquare, FiSearch } from "react-icons/fi";
import { sortConversationMessageParts, sortConversationMessages, type GuiConversationMessage, type GuiConversationMessagePart, type GuiConversationThread } from "../../gui-shared/src";
import { text } from "./app-model";
import { conversationThreads } from "./conversation-fixtures";

export function CommsConversationSurface({ mode }: { mode: "channels" | "directMessages" | "people" }) {
  const conversations = mode === "directMessages" ? conversationThreads.filter((thread) => thread.conversation.type === "dm" || thread.conversation.type === "group_dm") : conversationThreads.filter((thread) => thread.conversation.type === "channel");
  const selectedThread = conversations[0] ?? conversationThreads[0];
  const partsByMessage = new Map<string, GuiConversationMessagePart[]>();

  for (const part of sortConversationMessageParts(selectedThread.parts)) {
    partsByMessage.set(part.message_id, [...(partsByMessage.get(part.message_id) ?? []), part]);
  }

  return (
    <section className="chat-surface comms-surface" aria-label={mode === "directMessages" ? text.directMessages : text.channels} data-tour="comms-conversations">
      <aside className="chat-thread-panel conversation-list-panel" aria-label="Conversation list">
        <header className="chat-thread-header">
          <div>
            <p className="eyebrow">Unified conversation model</p>
            <h2>{mode === "directMessages" ? <FiAtSign aria-hidden="true" /> : <FiHash aria-hidden="true" />} {mode === "directMessages" ? text.directMessages : text.channels}</h2>
          </div>
          <button disabled title="Creating conversations needs encrypted transport and audited write routes" type="button">Create</button>
        </header>
        <label className="conversation-search"><FiSearch aria-hidden="true" /><span className="sr-only">Search conversations</span><input disabled placeholder="Search channels, DMs, mentions" /></label>
        <div className="notice compact-notice">{text.simplexReady}</div>
        <ul className="conversation-list">
          {conversations.map((thread) => <ConversationListItem key={thread.conversation.id} thread={thread} />)}
        </ul>
      </aside>
      <div className="chat-thread-panel conversation-detail-panel">
        <header className="chat-thread-header">
          <div>
            <p className="eyebrow">{selectedThread.conversation.scope.workspace_ref} · {selectedThread.conversation.status}</p>
            <h2>{selectedThread.conversation.type === "channel" ? <FiHash aria-hidden="true" /> : <FiMessageSquare aria-hidden="true" />} {selectedThread.conversation.title}</h2>
          </div>
          <span className="count-pill">{participantSummary(selectedThread)}</span>
        </header>
        <div className="participant-strip">
          {selectedThread.participants.map((participant) => <span key={participant.id}>{participant.display_name}<small>{participant.kind}</small></span>)}
        </div>
        <div className="chat-message-list" data-tour="comms-message-timeline">
          {sortConversationMessages(selectedThread.messages).map((message) => <ConversationMessageRow key={message.id} message={message} parts={partsByMessage.get(message.id) ?? []} thread={selectedThread} />)}
        </div>
        <form className="chat-composer" aria-label="Conversation composer">
          <textarea disabled placeholder={text.chatInputPlaceholder} />
          <button disabled title="Sending messages needs the encrypted transport adapter" type="button">Send</button>
        </form>
      </div>
    </section>
  );
}

function ConversationListItem({ thread }: { thread: GuiConversationThread }) {
  const latestMessage = sortConversationMessages(thread.messages).at(-1);
  const unread = unreadCount(thread);

  return (
    <li>
      <button className="surface-link" type="button">
        <span className="surface-icon" aria-hidden="true">{thread.conversation.type === "channel" ? <FiHash /> : <FiMessageSquare />}</span>
        <span className="surface-copy"><strong>{thread.conversation.title}</strong><small>{latestMessage ? latestMessage.created_at : "No messages yet"}</small></span>
        {unread > 0 ? <em>{unread}</em> : null}
      </button>
    </li>
  );
}

function ConversationMessageRow({ message, parts, thread }: { message: GuiConversationMessage; parts: GuiConversationMessagePart[]; thread: GuiConversationThread }) {
  const sender = thread.participants.find((participant) => participant.id === message.sender_participant_id);
  const reactions = thread.reactions.filter((reaction) => reaction.message_id === message.id);
  const speaker = message.sender_kind === "human" ? "user" : "assistant";

  return (
    <article className={`chat-bubble ${speaker}`} data-sender-kind={message.sender_kind}>
      <strong>{sender?.display_name ?? message.sender_kind}</strong>
      {parts.map((part) => <p key={part.id}>{part.text ?? part.kind}</p>)}
      <small>{message.status} · {message.created_at}</small>
      {reactions.length > 0 ? <div className="reaction-row">{reactions.map((reaction) => <span key={reaction.id}>{reaction.reaction}</span>)}</div> : null}
    </article>
  );
}

function participantSummary(thread: GuiConversationThread): string {
  const active = thread.participants.filter((participant) => participant.membership_state === "active").length;
  return `${active} members`;
}

function unreadCount(thread: GuiConversationThread): number {
  const lastSequence = Math.max(0, ...thread.messages.map((message) => message.sequence));
  const localRead = thread.read_states[0]?.last_read_sequence ?? 0;
  return Math.max(0, lastSequence - localRead);
}
