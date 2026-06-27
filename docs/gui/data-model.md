<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GUI data model

This document expands the data sketch in `docs/gui/control-plane.md` into the
first implementation contract for the aidevops GUI/control plane. It is a
planning artifact for future `packages/gui-core` schemas, SQLite migrations, API
contracts, and fixtures.

The model is intentionally generic. Providers, accounts, resources, projects,
routines, machines, bookmarks, capabilities, integrations, task capsules, and
audit events are separate entities so the GUI can describe mixed infrastructure
without becoming provider-specific or secret-bearing.

## Design goals

- Model local-first aidevops status, infrastructure inventory, provider
  bookmarks, routines, calendar/contact integrations, and machine delegation.
- Keep git platforms, aidevops helpers, scheduler definitions, and provider
  APIs as sources of truth where they already own state.
- Store secret references and health signals only, never secret values, partial
  values, raw credential files, copied clipboard contents, or secret-bearing
  logs.
- Prefer stable IDs, typed categories, and validated metadata extensions over
  provider-specific tables.
- Make provider-specific details queryable and testable without coupling the
  core graph to one vendor.
- Make future migrations and schema tests mandatory before write flows.

## Core entities

### Identity

An `Identity` represents the human, business, team, automation role, service, or
recovery owner behind accounts and machines.

Suggested fields:

- `id`: stable internal ID.
- `name`: display name.
- `identity_type`: `person`, `business`, `team`, `automation`, `service`, or
  `recovery`.
- `trust_level`: local trust label such as `owner`, `admin`, `operator`,
  `limited`, or `unknown`.
- `recovery_notes_ref`: reference to non-secret recovery notes.
- `status`: `active`, `suspended`, `retired`, or `unknown`.
- `created_at`, `updated_at`.

Identity records do not store private keys, passphrases, recovery codes, or raw
identity documents.

### Provider

A `Provider` describes an external or local provider family. It is not an
account and it is not a resource instance.

Suggested fields:

- `id`: stable internal ID.
- `name`: provider name.
- `provider_type`: typed category such as `dns`, `registrar`, `git`, `hosting`,
  `email`, `messaging`, `social`, `vpn`, `proxy`, `cloud`, `orchestrator`,
  `server_app`, `calendar`, `contacts`, `ai_model`, `local_app`, or `other`.
- `homepage_ref`: URL/reference string from trusted setup data.
- `recommendation_status`: `recommended`, `experimental`, `avoided`,
  `user_owned`, or `unknown`.
- `notes_ref`: setup notes or documentation reference.
- `metadata_json`: provider bookmark and adapter metadata validated by schema.
- `created_at`, `updated_at`.

Provider entries can exist before any account is connected so the GUI can render
provider bookmarks and setup guidance.

### Account

An `Account` links an identity to a provider account, tenant, org, workspace,
email inbox, social profile, or local app profile.

Suggested fields:

- `id`: stable internal ID.
- `identity_id`: owning `Identity`.
- `provider_id`: provider for the account.
- `account_type`: `personal`, `business`, `admin`, `billing`, `automation`,
  `service`, `recovery`, `workspace`, or `unknown`.
- `display_name_ref`: non-secret display reference.
- `username_ref`: username/email/profile reference; redact where needed.
- `secret_refs`: names or IDs in aidevops secrets, gopass, Vaultwarden, OS
  keychain, or provider-native secret storage.
- `mfa_status`: `configured`, `missing`, `unknown`, or `not_applicable`.
- `recovery_status`: `configured`, `missing`, `unknown`, or `not_applicable`.
- `blast_radius`: local risk note or enum.
- `status`: `active`, `needs_attention`, `disabled`, `retired`, or `unknown`.
- `metadata_json`: validated account-specific extensions.
- `created_at`, `updated_at`.

`secret_refs` must identify where a secret lives, not reveal the secret.

### Resource

A `Resource` is any infrastructure object, app, service, namespace, endpoint,
or managed asset that can be related to accounts, projects, routines, and
machines.

Suggested fields:

- `id`: stable internal ID.
- `resource_type`: category from the resource taxonomy below.
- `provider_id`: optional provider link.
- `account_id`: optional account link.
- `owner_identity_id`: owning identity where it differs from the account.
- `name`: local display name.
- `environment`: `local`, `dev`, `staging`, `prod`, `personal`, `client`,
  `shared`, or `unknown`.
- `purpose`: concise non-secret purpose.
- `status`: `healthy`, `degraded`, `missing`, `disabled`, `retired`, or
  `unknown`.
- `health_status`: last known health summary.
- `update_status`: update/posture summary.
- `backup_status`: backup summary.
- `trust_scope`: permitted operation scope.
- `allowed_operations`: read/write/destructive capability labels.
- `secret_refs`: linked secret references only.
- `metadata_json`: schema-validated resource extension.
- `notes_ref`, `setup_guide_ref`, `verification_ref`.
- `created_at`, `updated_at`, `last_seen_at`.

The core resource row stays small. Provider-specific fields live in
`metadata_json` and must have a schema keyed by `resource_type` and provider.

### Machine

A `Machine` represents local or paired compute that can run aidevops, OpenCode,
helpers, runners, routines, or delegated task capsules.

Suggested fields:

- `id`: stable internal ID.
- `resource_id`: backing `Resource` when the machine is also a server, laptop,
  VM, container host, or runner.
- `machine_identity_pubkey`: public identity key only.
- `display_name`.
- `os_family`: `macos`, `windows`, `ubuntu`, `arch`, `omarchy`, `ios`,
  `android`, `grapheneos`, `linux_other`, or `unknown`.
- `capabilities`: capability labels such as `opencode`, `aidevops`,
  `git_runner`, `cloudron_admin`, `docker`, `podman`, `calendar_sync`, or
  `contacts_sync`.
- `scopes`: repo, project, routine, resource, and action scopes granted to the
  machine.
- `heartbeat_status`, `last_seen_at`, `safe_disable_state`.
- `metadata_json`: hardware, runtime, scheduler, or local app metadata.
- `created_at`, `updated_at`.

Machines own local enforcement. A hosted control plane records grants and audit
evidence but does not inherit unlimited machine authority.

### Project

A `Project` maps GUI inventory to git and aidevops project state.

Suggested fields:

- `id`: stable internal ID.
- `git_remote`: remote URL/reference.
- `repo_slug`: provider repo slug where available.
- `repos_json_ref`: source row or path reference from `repos.json`.
- `owner_identity_id`.
- `provider_id`, `account_id`.
- `status`: `active`, `paused`, `archived`, `missing`, or `unknown`.
- `linked_resources`, `linked_routines`, `linked_capabilities`.
- `metadata_json`: issue/PR source, default branch, managed-repo flags, or
  worker-policy metadata.
- `created_at`, `updated_at`, `last_indexed_at`.

Git hosts remain source of truth for issues, PRs, branches, and collaboration.
The GUI stores references and projections, not a second issue tracker.

### Routine

A `Routine` describes scheduled or manually triggered aidevops operations.

Suggested fields:

- `id`: stable internal ID.
- `source_ref`: TODO/routine definition, command doc, helper config, or
  scheduler reference.
- `schedule`: cron/launchd/systemd/Cloudron schedule reference where applicable.
- `runner_type`: `script`, `agent`, `helper`, `local_app`, or `external`.
- `enabled_state`: `enabled`, `disabled`, `paused`, or `unknown`.
- `next_run_at`, `last_run_at`, `last_duration_ms`.
- `last_result`: `success`, `failed`, `skipped`, `cancelled`, or `unknown`.
- `failure_reason_ref`: non-secret evidence pointer.
- `linked_resources`, `linked_projects`, `linked_services`.
- `linked_secret_refs`.
- `metadata_json`: retry policy, output retention, or LLM-backed agent metadata.
- `created_at`, `updated_at`.

Routine definitions and scheduler helpers remain canonical until a later ADR
changes that contract.

### Bookmark

A `Bookmark` stores provider recommendation and catalog content.

Suggested fields:

- `id`: stable internal ID.
- `provider_id`.
- `category`: provider category or use-case category.
- `recommendation`: `recommended`, `experimental`, `avoided`, `owned`, or
  `unknown`.
- `affiliate_ref`: optional reference to affiliate metadata, not an operational
  credential.
- `price_band`, `privacy_score`, `open_source_score`, `freedom_score`.
- `rationale`: concise editorial rationale.
- `pros`, `cons`, `tags`.
- `setup_guide_ref`, `helper_ref`, `verification_ref`.
- `metadata_json`: validated content metadata such as region or supported
  products.
- `created_at`, `updated_at`.

Affiliate metadata must be treated as content metadata. It may include campaign
IDs or disclosure references later, but it must not be mixed with secret refs or
provider API credentials.

### Capability

A `Capability` is a discoverable aidevops ability surfaced by agents, services,
tools, workflows, helpers, or skills.

Suggested fields:

- `id`: stable internal ID.
- `name`, `summary`.
- `capability_type`: `agent`, `tool`, `service`, `workflow`, `helper`, `skill`,
  `integration`, or `other`.
- `doc_ref`, `agent_ref`, `service_ref`, `helper_ref`.
- `setup_requirements`.
- `verification_refs`.
- `required_secret_refs`: names only.
- `linked_providers`, `linked_resources`, `linked_routines`.
- `metadata_json`.
- `created_at`, `updated_at`, `last_indexed_at`.

The GUI should store concise summaries and references, not duplicate long agent
instructions.

### Integration

An `Integration` links an account/resource pair to a concrete external protocol,
local app, or helper-managed connection.

Suggested fields:

- `id`: stable internal ID.
- `integration_type`: `github`, `gitlab`, `gitea`, `forgejo`, `cloudron`,
  `coolify`, `caldav`, `carddav`, `imap`, `smtp`, `xmpp`, `xmtp`, `nostr`,
  `nextcloud`, `local_calendar`, `local_contacts`, `local_app`, `vpn`,
  `proxy`, or `other`.
- `account_id`, `resource_id`.
- `secret_refs`: credential references only.
- `health_status`, `last_checked_at`.
- `read_scope`, `write_scope`.
- `metadata_json`: protocol endpoint references, collection IDs, sync direction,
  or adapter details.
- `created_at`, `updated_at`.

CalDAV/CardDAV support should model calendars, address books, sync health,
service-account boundaries, and which routines or agents may read or write each
collection.

### TaskCapsule

A `TaskCapsule` represents future scoped delegation between machines.

Suggested fields:

- `id`: stable internal ID.
- `issuer_machine_id`, `target_machine_id`.
- `repo_scope`, `project_scope`, `resource_scope`.
- `allowed_actions`: helper/action IDs and risk ceiling.
- `human_approval_requirement`.
- `expires_at`, `not_before_at`, `revoked_at`.
- `nonce_ref` or replay-protection reference.
- `audit_ref`, `result_ref`.
- `status`: `issued`, `accepted`, `running`, `completed`, `failed`, `expired`,
  or `revoked`.
- `metadata_json`: signed envelope metadata.
- `created_at`, `updated_at`.

Capsules are not bearer tokens for arbitrary shell access. They must be scoped,
expiring, replay-protected, and enforced locally by the target machine.

### Conversation

A `Conversation` is the shared collaboration container for AI sessions,
channels, direct messages, group DMs, and worker/event threads.

Suggested fields:

- `id`: stable internal ID.
- `conversation_type`: `ai_session`, `channel`, `dm`, `group_dm`, or
  `worker_thread`.
- `title`: display name or generated session title.
- `tenant_ref`, `workspace_ref`, `repo_ref`: local ownership and repo scope.
- `source_ref`: OpenCode session, imported channel, worker run, or local draft
  source reference.
- `status`: `active`, `archived`, or `read_only`.
- `created_at`, `updated_at`.

Conversation scope is mandatory. The GUI must be able to prove that a thread is
owned by the current local tenant/workspace and, where applicable, bound to the
selected repo before rendering protected message payloads.

### ConversationParticipant

A `ConversationParticipant` links a human, AI assistant, worker, or system bot to
a conversation.

Suggested fields:

- `id`: stable internal ID.
- `conversation_id`.
- `participant_kind`: `human`, `ai_assistant`, `worker`, or `system_bot`.
- `display_name`: local display label.
- `identity_ref`: optional `Identity` reference for human participants.
- `agent_ref`: optional aidevops/OpenCode agent reference.
- `worker_ref`: optional worker or task-capsule reference.
- `membership_state`: `active`, `invited`, `left`, or `removed`.
- `joined_at`.

Membership gates read access. Removed participants must not be treated as active
readers even if old messages reference them as historical senders.

### ConversationMessage

A `ConversationMessage` is an ordered envelope in a conversation. Payloads live
in message parts so AI, event, and GenUI content can share the same timeline.

Suggested fields:

- `id`: stable internal ID.
- `conversation_id`.
- `sender_participant_id`: nullable for system-generated markers.
- `sender_kind`: `human`, `ai_assistant`, `worker`, `system_bot`, or `system`.
- `sequence`: monotonically increasing conversation-local order.
- `status`: `draft`, `sent`, `delivered`, `failed`, or `redacted`.
- `usage_metadata`: nullable provider/model/token/cost reference metadata.
- `created_at`, `edited_at`.

Message ordering uses `sequence` first and timestamp only as a deterministic
tie-breaker. Import adapters should preserve source ordering and assign local
sequence values before rendering.

### ConversationMessagePart

A `ConversationMessagePart` stores the ordered pieces that make up a message.

Suggested fields:

- `id`: stable internal ID.
- `message_id`.
- `part_kind`: `text`, `file`, `tool_call`, `source`, `tambo_component`,
  `approval_prompt`, or `event_marker`.
- `ordinal`: message-local order.
- `text`: text payload when applicable.
- `payload_json`: schema-validated non-secret structured payload.
- `file_ref`: file/attachment reference, not raw file bytes.
- `source_ref`: citation, helper, workflow, or evidence reference.

Tambo component payloads are message parts, not separate conversation owners.
Tool calls, approval prompts, and event markers may carry structured payloads,
but those payloads must not include secret values, private keys, raw cookies, or
credential-bearing command output.

### ConversationReaction and read state

`ConversationReaction` and `ConversationReadState` keep social feedback and read
progress outside message payloads.

Suggested reaction fields:

- `id`, `message_id`, `participant_id`, `reaction`, `created_at`.

Suggested read-state fields:

- `conversation_id`, `participant_id`, `last_read_message_id`,
  `last_read_sequence`, `updated_at`.

Read state is participant-scoped and conversation-scoped. It must not leak which
private repo or protected channel another tenant/workspace can see.

### AuditEvent

An `AuditEvent` records non-secret evidence about reads, writes, confirmations,
delegation, and helper/API outcomes.

Suggested fields:

- `id`: stable internal ID.
- `actor_ref`: user, identity, machine, session, or task capsule reference.
- `machine_id`.
- `origin_ip_ref`: redacted or local-only network reference where useful.
- `action`: operation identifier.
- `target_ref`: target entity reference.
- `risk_class`: `read`, `write`, `destructive`, or `delegated`.
- `confirmation_ref`: confirmation evidence pointer for high-risk actions.
- `result`: `success`, `failed`, `blocked`, `cancelled`, or `unknown`.
- `redacted_metadata`: structured non-secret evidence.
- `created_at`.

Audit events must not contain credential values, private repo names intended for
public export, raw command output with secrets, or private key material.

## Resource taxonomy

`Resource.resource_type` should be broad enough to cover the initial families in
`docs/gui/control-plane.md` while keeping room for provider-specific metadata.

| Family | Resource types | Relationship examples |
|--------|----------------|-----------------------|
| Domains and DNS | `domain`, `registrar_account`, `dns_zone`, `dns_record`, `dns_provider_zone` | A `domain` is registered through a registrar `Account`, delegates to one or more `dns_zone` resources, and links to hosting/email resources. |
| Git platforms | `git_host`, `git_org`, `git_repo`, `git_runner`, `git_app`, `git_token_scope` | A `Project` references a `git_repo`; a `git_runner` is also a `Machine` or linked to one; account metadata stores role and 2FA state. |
| Hosting and cloud | `hosting_account`, `vps`, `server`, `serverless_app`, `object_bucket`, `database`, `cdn_property` | A `server` belongs to a hosting account, runs containers/apps, and links to backup and monitoring resources. |
| Email | `email_domain`, `mailbox`, `smtp_service`, `imap_service`, `mailing_list`, `email_alias` | An email account links an identity to mail resources and may provide recovery channels for other accounts. |
| Messaging and social | `messaging_account`, `messaging_group`, `social_profile`, `social_page`, `social_app` | A social profile belongs to an identity/account and can link to routines for posting or monitoring. |
| VPNs and proxies | `vpn_network`, `vpn_node`, `proxy_service`, `tunnel`, `overlay_network` | VPN or proxy resources model transport and reachability, not authorization. Allowed operations remain on accounts/machines. |
| Servers and devices | `physical_server`, `vm`, `laptop`, `desktop`, `mobile_device`, `tablet`, `iot_device` | Device resources can back `Machine` records and expose OS, posture, backup, and compute capability metadata. |
| Containers | `container_host`, `container`, `compose_stack`, `image`, `volume`, `network` | A container host runs containers and volumes; app resources link to their deployment container. |
| Orchestrators | `cloudron_instance`, `coolify_instance`, `ubicloud_project`, `kubernetes_cluster`, `nomad_cluster`, `orchestrator_app` | Orchestrator instances own app resources, deployment targets, backups, domains, and secrets by reference. |
| Operating systems and fleets | `os_install`, `device_fleet`, `mdm_profile`, `package_manager`, `update_channel` | Machines link to OS resources for update health, capabilities, and support policy. |
| Server apps | `nextcloud_app`, `collabora_app`, `pastebin_app`, `docuseal_app`, `postiz_app`, `espocrm_app`, `odoo_app`, `vaultwarden_app`, `fider_app`, `gitea_app`, `forgejo_app`, `server_app_other` | App resources link to domains, databases, object stores, secret refs, projects, routines, and backups. |
| Calendar and contacts | `calendar_service`, `calendar_collection`, `contacts_service`, `address_book`, `sync_client` | CalDAV/CardDAV integrations link accounts, collections, local apps, routines, and secret refs. |
| Local aidevops and OpenCode | `aidevops_install`, `opencode_runtime`, `session_log`, `helper_set`, `config_file` | A local machine owns runtime resources, helper capability records, routine state, and session references. |
| AI and agent systems | `agent_runtime`, `model_provider`, `model_account`, `knowledge_repo`, `task_queue` | Capabilities link to providers/accounts while model/API secrets stay as references. |

Relationships should be stored through typed link tables rather than embedded
arrays once implementation begins. A link should include source entity, target
entity, relation type, evidence/source reference, and timestamps.

## Relationship patterns

Use typed relationships to avoid hard-coding provider assumptions:

- `Identity owns Account`.
- `Account belongs_to Provider`.
- `Account administers Resource`.
- `Resource depends_on Resource`.
- `Resource exposes Integration`.
- `Resource backs Machine`.
- `Machine can_run Routine`.
- `Machine accepts TaskCapsule`.
- `Project uses Resource`.
- `Project references git_repo Resource`.
- `Routine reads/writes Resource`.
- `Routine uses secret_ref`.
- `Capability documents Integration`.
- `Bookmark recommends Provider`.
- `AuditEvent records action_on target`.

Example: a Cloudron-hosted Nextcloud calendar setup can be represented as one
`Provider` for Cloudron, one `Account` for the Cloudron admin, a
`cloudron_instance` resource, a `nextcloud_app` resource, `calendar_service` and
`contacts_service` resources, `caldav` and `carddav` integrations, local
`sync_client` resources on devices, and routines that read/write selected
collections through scoped secret references.

Example: a git runner can be represented as a `git_runner` resource linked to a
`Machine`, a `Project`, a git provider `Account`, allowed repo scopes, and audit
events for dispatch, execution, and result upload.

## Provider-specific metadata extensions

Provider-specific fields belong in validated metadata objects, not in new core
columns for each provider. The implementation should define schemas by a stable
extension key:

```text
metadata_schema_key = <entity>.<resource_or_provider_type>.<provider_slug>.<version>
```

Examples:

- `resource.dns_zone.cloudflare.v1` for Cloudflare zone IDs and plan metadata.
- `resource.git_repo.github.v1` for repo node IDs, visibility, and default
  branch projections.
- `integration.caldav.nextcloud.v1` for collection references, sync direction,
  and safe read/write scope.
- `resource.server_app.cloudron.v1` for app ID, domain ref, backup policy, and
  update channel.
- `bookmark.provider_catalog.generic.v1` for price band, region, affiliate
  disclosure reference, and recommendation rationale.

Extension rules:

- Metadata must be JSON-serializable and schema-validated at write time.
- Metadata may store provider IDs, non-secret endpoint references, product tiers,
  regions, feature flags, and timestamps.
- Metadata must not store API tokens, passwords, private keys, recovery codes,
  cookie values, SSH private keys, or secret-bearing logs.
- Metadata fields that may reveal sensitive local paths, private repo names, or
  client identifiers need local-only export controls before sync or public issue
  generation.
- Unknown extension versions should be preserved for read-only display but not
  mutated until migrated or validated.

## Secret reference contract

Every entity that needs credentials uses a `secret_refs` array or equivalent
link table. A secret reference should contain:

- Secret name or external secret ID.
- Backend type such as `aidevops`, `gopass`, `vaultwarden`, `os_keychain`,
  `provider_native`, or `unknown`.
- Purpose label such as `api_token`, `oauth_client`, `ssh_key`, `password`,
  `caldav_password`, or `webhook_secret`.
- Health state and last checked timestamp.
- Rotation/check helper reference where available.

The GUI may show configured/missing/invalid/unknown states and next-step setup
guidance. It must not retrieve, persist, render, export, or diff raw secret
values.

## Migration expectations

Future implementation should treat the schema as an explicit product contract:

- Add SQLite migrations for every persisted table, index, and link table.
- Use stable migration IDs and deterministic ordering.
- Include forward migrations before introducing routes that write the new data.
- Preserve unknown provider metadata when migrating known core fields.
- Include fixture migrations for representative local-only, Cloudron, git,
  provider-bookmark, CalDAV/CardDAV, routine, and machine-delegation examples.
- Provide rollback or recovery guidance for destructive schema changes, even if
  SQLite rollback migrations are not automated initially.
- Require exported backups before migrations that delete or rewrite user-owned
  annotations.

The first read-only dashboard may index transient projections, but any write
flow must have migration coverage before release.

## Schema-test expectations

Future `packages/gui-core` tests should prove:

- Required entities validate with minimal fixtures.
- Each resource family listed above has at least one valid fixture.
- Provider-specific metadata accepts valid fixtures and rejects wrong provider or
  wrong version payloads.
- Secret refs validate without exposing secret values.
- API response fixtures redact secret-bearing fields.
- Relationship fixtures can express domains/DNS, git runners, Cloudron apps,
  CalDAV/CardDAV, routines, local apps, and task capsules.
- Unknown metadata extension versions are preserved read-only.
- Migration tests upgrade fixtures from the previous schema version.
- Audit event tests reject raw secret values in metadata and logs.

## Related documents

- `docs/gui/control-plane.md`
- `docs/gui/adr-0001-product-scope-stack-repo-layout.md`
- `docs/gui/adr-0002-trust-boundaries.md`
- `docs/gui/adr-0003-resource-graph.md`
