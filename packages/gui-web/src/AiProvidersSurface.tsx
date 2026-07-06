import { useState } from "react";
import type { IconType } from "react-icons";
import { FiAlertTriangle, FiCheckCircle, FiClock, FiCommand, FiGlobe, FiInfo, FiKey, FiPlusCircle, FiRefreshCw, FiRepeat, FiShield, FiTerminal, FiThumbsUp, FiTool } from "react-icons/fi";
import type { GuiOAuthProviderSummary, GuiStatusData } from "../../gui-shared/src";
import { text } from "./app-model";

type AiProviderGroupId = "recommended-oauth" | "oauth-pool";

interface AiProviderCatalogEntry {
  id: GuiOAuthProviderSummary["provider"];
  displayName: string;
  group: AiProviderGroupId;
  authKind: string;
  description: string;
  connectionHint: string;
  recommended: boolean;
  recommendation?: string;
  opencodeProviders: string[];
  capabilities: string[];
  Icon: IconType;
}

const AI_PROVIDER_GROUPS: Array<{ detail: string; id: AiProviderGroupId; label: string }> = [
  { id: "recommended-oauth", label: "Recommended OAuth pools", detail: "First-class providers to connect for aidevops model rotation and worker resilience." },
  { id: "oauth-pool", label: "OAuth pool compatible", detail: "Additional OpenCode providers that can be represented by the local aidevops OAuth pool." },
];

const AI_PROVIDER_CATALOG: AiProviderCatalogEntry[] = [
  {
    id: "openai",
    displayName: "OpenAI",
    group: "recommended-oauth",
    authKind: "OAuth pool",
    description: "Primary coding and reasoning models through OpenCode's OpenAI provider and the aidevops OAuth pool.",
    connectionHint: "Use OpenCode auth login, choose OpenAI Pool, then add each account email separately.",
    recommended: true,
    recommendation: "Recommended for strong coding coverage and current OAuth rotation support.",
    opencodeProviders: ["openai", "openai-pool", "openrouter/openai"],
    capabilities: ["coding", "reasoning", "pool rotation"],
    Icon: FiCommand,
  },
  {
    id: "cursor",
    displayName: "Cursor",
    group: "recommended-oauth",
    authKind: "OAuth proxy",
    description: "Cursor account pool routed through the aidevops Cursor proxy for OpenCode-compatible model access.",
    connectionHint: "Use OpenCode auth login, choose Cursor Pool, then keep every account as a separate pool entry.",
    recommended: true,
    recommendation: "Recommended when Cursor subscriptions provide useful fallback capacity.",
    opencodeProviders: ["cursor", "cursor-pool"],
    capabilities: ["subscription reuse", "proxy", "fallback capacity"],
    Icon: FiTerminal,
  },
  {
    id: "zai",
    displayName: "Z.ai",
    group: "recommended-oauth",
    authKind: "OAuth pool",
    description: "GLM/Z.ai provider family surfaced by OpenCode as zai, z-ai, and zhipuai model prefixes.",
    connectionHint: "Track Z.ai as a pool target now; audited OAuth connection routes should be added before enabling writes.",
    recommended: true,
    recommendation: "Recommended for GLM coding and low-friction non-US provider diversity.",
    opencodeProviders: ["zai", "zai-coding-plan", "zhipuai", "openrouter/z-ai"],
    capabilities: ["GLM models", "provider diversity", "planned OAuth"],
    Icon: FiTool,
  },
  {
    id: "anthropic",
    displayName: "Anthropic",
    group: "oauth-pool",
    authKind: "OAuth pool",
    description: "Claude provider pool for compatible Anthropic and Claude Code sessions.",
    connectionHint: "Use OpenCode auth login, choose Anthropic Pool, then rotate accounts with the local OAuth pool helper.",
    recommended: false,
    opencodeProviders: ["anthropic", "openrouter/anthropic", "poe/anthropic"],
    capabilities: ["Claude models", "OAuth", "account rotation"],
    Icon: FiShield,
  },
  {
    id: "google",
    displayName: "Google Gemini",
    group: "oauth-pool",
    authKind: "OAuth pool",
    description: "Gemini and Vertex-compatible OAuth accounts represented as metadata-only pool entries.",
    connectionHint: "Use OpenCode auth login, choose Google Pool, and keep Workspace or AI subscription accounts separate.",
    recommended: false,
    opencodeProviders: ["google", "gemini", "openrouter/google", "vercel/google"],
    capabilities: ["Gemini", "Vertex", "multimodal"],
    Icon: FiGlobe,
  },
];

export function AiProvidersSurface({ status }: { status: GuiStatusData }) {
  const [activeGroup, setActiveGroup] = useState<AiProviderGroupId | "all">("all");
  const [query, setQuery] = useState("");
  const providersById = new Map(status.oauth_pool.providers.map((provider) => [provider.provider, provider]));
  const catalogCards = AI_PROVIDER_CATALOG.map((entry) => ({ entry, provider: providersById.get(entry.id) ?? emptyProviderSummary(entry.id) }));
  const normalizedQuery = query.trim().toLowerCase();
  const visibleCards = catalogCards.filter(({ entry }) => {
    const matchesGroup = activeGroup === "all" || entry.group === activeGroup;
    const searchable = [entry.displayName, entry.id, entry.authKind, entry.description, entry.connectionHint, ...entry.opencodeProviders, ...entry.capabilities].join(" ").toLowerCase();

    return matchesGroup && (normalizedQuery.length === 0 || searchable.includes(normalizedQuery));
  });
  const totalAccounts = catalogCards.reduce((sum, card) => sum + card.provider.total, 0);
  const availableAccounts = catalogCards.reduce((sum, card) => sum + card.provider.available, 0);
  const recommendedConnected = catalogCards.filter((card) => card.entry.recommended && card.provider.configured).length;
  const needsAttention = catalogCards.filter((card) => card.provider.auth_errors > 0 || card.provider.rate_limited > 0 || card.provider.pending_token).length;
  const summaryCards = [
    { label: "accounts", value: String(totalAccounts), detail: "metadata-only pool entries" },
    { label: "available", value: String(availableAccounts), detail: "ready after cooldown checks" },
    { label: "recommended", value: `${recommendedConnected}/3`, detail: "OpenAI, Cursor, and Z.ai" },
    { label: "attention", value: String(needsAttention), detail: "auth errors, rate limits, pending tokens" },
  ];

  return (
    <section className="surface-page ai-providers-surface" aria-label={text.aiProviders}>
      <div className="hero-panel ai-provider-hero">
        <div className="section-heading split-heading">
          <div>
            <p className="eyebrow">{status.oauth_pool.path_ref}</p>
            <h2>{text.aiProviders}</h2>
            <p>{text.aiProvidersIntro} Manage provider connections as OAuth pool metadata, with one card per OpenCode provider family and one row per account.</p>
          </div>
          <span className="count-pill">{status.oauth_pool.value_policy}</span>
        </div>
        <div className="ai-provider-summary-grid">
          {summaryCards.map((card) => (
            <article className="ai-provider-summary-card" key={card.label}>
              <span>{card.label}</span>
              <strong>{card.value}</strong>
              <small>{card.detail}</small>
            </article>
          ))}
        </div>
      </div>
      <div className="notice compact-notice" role="note">
        Data-leaves-device warning: provider accounts can process prompts outside this machine. Use `data_classification` and `runtime_policy` metadata to require Local AI or explicit provider approval for confidential work.
      </div>
      <section className="panel ai-provider-catalog-panel" aria-label="AI provider catalog">
        <div className="provider-toolbar">
          <label className="provider-search">
            <FiInfo aria-hidden="true" />
            <span className="sr-only">Search AI providers</span>
            <input aria-label="Search AI providers" onChange={(event) => setQuery(event.target.value)} placeholder="Search providers, model prefixes, or capabilities" type="search" value={query} />
          </label>
          <div aria-label="Provider group filters" className="provider-filter-chips" role="toolbar">
            <button className={activeGroup === "all" ? "active" : ""} onClick={() => setActiveGroup("all")} type="button">All <span>{catalogCards.length}</span></button>
            {AI_PROVIDER_GROUPS.map((group) => (
              <button className={activeGroup === group.id ? "active" : ""} key={group.id} onClick={() => setActiveGroup(group.id)} type="button">
                {group.label} <span>{catalogCards.filter((card) => card.entry.group === group.id).length}</span>
              </button>
            ))}
          </div>
        </div>
        {visibleCards.length === 0 ? (
          <p className="empty-state">No providers match this filter.</p>
        ) : (
          AI_PROVIDER_GROUPS.map((group) => {
            const groupCards = visibleCards.filter((card) => card.entry.group === group.id);
            if (groupCards.length === 0) {
              return null;
            }

            return (
              <section className="provider-section" key={group.id} aria-label={group.label}>
                <div className="section-heading split-heading provider-section-heading">
                  <div>
                    <p className="eyebrow">{groupCards.length} provider{groupCards.length === 1 ? "" : "s"}</p>
                    <h3>{group.label}</h3>
                    <p>{group.detail}</p>
                  </div>
                </div>
                <div className="provider-grid">
                  {groupCards.map((card) => <ProviderCard entry={card.entry} key={card.entry.id} provider={card.provider} />)}
                </div>
              </section>
            );
          })
        )}
      </section>
    </section>
  );
}

function ProviderCard({ entry, provider }: { entry: AiProviderCatalogEntry; provider: GuiOAuthProviderSummary }) {
  const Icon = entry.Icon;
  const connectLabel = provider.configured ? "Add another account" : "Connect account";
  const connectionTitle = `${entry.connectionHint} Browser write routes are read-only until audited provider actions are implemented.`;

  return (
    <article className={entry.recommended ? "provider-card provider-card-recommended" : "provider-card"}>
      <header className="provider-card-header">
        <div className="provider-identity">
          <span className={`provider-avatar provider-avatar-${entry.id}`} aria-hidden="true"><Icon /></span>
          <div>
            <p className="eyebrow">{entry.authKind}</p>
            <div className="provider-title-row">
              <h3>{entry.displayName}</h3>
              {entry.recommended ? <span className="recommendation-badge" title={entry.recommendation}><FiThumbsUp aria-hidden="true" />Recommended</span> : null}
            </div>
            <p>{entry.description}</p>
          </div>
        </div>
        <div className="provider-count-stack">
          <strong>{provider.available}/{provider.total}</strong>
          <ProviderStatusBadge provider={provider} />
        </div>
      </header>
      <ul aria-label={`${entry.displayName} OpenCode provider prefixes`} className="provider-chip-row">
        {entry.opencodeProviders.map((prefix) => <li className="provider-chip" key={prefix}>{prefix}</li>)}
      </ul>
      <p className="provider-connection-hint">{entry.connectionHint}</p>
      <div className="repo-card-meta provider-metrics">
        <ProviderDetail label="active/idle" value={String(provider.active_or_idle)} />
        <ProviderDetail label="rate limited" value={String(provider.rate_limited)} />
        <ProviderDetail label="auth errors" value={String(provider.auth_errors)} />
        <ProviderDetail label="pending token" value={provider.pending_token ? "yes" : "no"} />
      </div>
      <ul aria-label={`${entry.displayName} capabilities`} className="provider-chip-row provider-capability-row">
        {entry.capabilities.map((capability) => <li className="provider-chip" key={capability}>{capability}</li>)}
      </ul>
      <fieldset className="provider-actions">
        <legend className="sr-only">{entry.displayName} planned management controls</legend>
        <button disabled title={connectionTitle} type="button"><FiPlusCircle aria-hidden="true" />{connectLabel}</button>
        <button disabled title="Read-only preview: rotation uses oauth-pool-helper.sh rotate after audited write routes land." type="button"><FiRepeat aria-hidden="true" />Rotate</button>
        <button disabled title="Read-only preview: health checks use oauth-pool-helper.sh check after audited write routes land." type="button"><FiRefreshCw aria-hidden="true" />Check</button>
        <button disabled title="Read-only preview: cooldown resets use oauth-pool-helper.sh reset-cooldowns after audited write routes land." type="button"><FiClock aria-hidden="true" />Cooldowns</button>
      </fieldset>
      {provider.accounts.length === 0 ? (
        <p className="empty-state compact-empty">No accounts in this pool yet. Multiple accounts are supported by adding a separate OAuth entry per email.</p>
      ) : (
        <ul className="provider-account-list">
          {provider.accounts.map((account) => (
            <li key={`${provider.provider}:${account.email_ref}`}>
              <strong>{account.email_ref}</strong>
              <span className="provider-account-status">{account.status}</span>
              <small>priority {account.priority ?? "default"}</small>
              <small>last used {account.last_used}</small>
              <small>expires {account.expires_at}</small>
              {account.cooldown_until ? <small>cooldown {account.cooldown_until}</small> : null}
              <button disabled title="Read-only preview: account management requires audited provider write routes." type="button"><FiKey aria-hidden="true" />Manage</button>
            </li>
          ))}
        </ul>
      )}
    </article>
  );
}

function ProviderStatusBadge({ provider }: { provider: GuiOAuthProviderSummary }) {
  const status = providerStatus(provider);
  const Icon = status.Icon;

  return <span className={`status-pill provider-health ${status.className}`}><Icon aria-hidden="true" />{status.label}</span>;
}

function providerStatus(provider: GuiOAuthProviderSummary): { Icon: IconType; className: string; label: string } {
  if (provider.auth_errors > 0) {
    return { Icon: FiAlertTriangle, className: "error", label: "auth attention" };
  }
  if (provider.rate_limited > 0) {
    return { Icon: FiClock, className: "warn", label: "rate limited" };
  }
  if (provider.pending_token) {
    return { Icon: FiKey, className: "warn", label: "pending token" };
  }
  if (provider.configured) {
    return { Icon: FiCheckCircle, className: "ready", label: "configured" };
  }

  return { Icon: FiInfo, className: "neutral", label: "not connected" };
}

function emptyProviderSummary(provider: GuiOAuthProviderSummary["provider"]): GuiOAuthProviderSummary {
  return {
    provider,
    configured: false,
    total: 0,
    available: 0,
    active_or_idle: 0,
    rate_limited: 0,
    auth_errors: 0,
    pending_token: false,
    accounts: [],
  };
}

function ProviderDetail({ label, value }: { label: string; value: string }) {
  return (
    <span>
      <small>{label}</small>
      <strong>{value}</strong>
    </span>
  );
}
