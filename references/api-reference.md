# V1 API reference

Every V1 endpoint with its parameters and response shape, for tasks beyond the module's four calls. Checked
against the InboxParse V1 implementation and its reference documentation. Base URL
`https://inboxparse.com/api/v1`; authentication and keys are in [client.md](client.md).

## Responses

| Kind | Shape |
|---|---|
| Single item | `{ "data": { ... } }` |
| Unpaginated list | `{ "data": [...], "count": 5 }` |
| Paginated list | `{ "data": [...], "pagination": { "next_cursor": "...", "has_more": true } }` |
| Error | `{ "error": { "message": "...", "code": "snake_case_code" } }`, codes in [error-codes.md](error-codes.md) |

Add `compact=true` to any endpoint to shorten every key and append a `_dict` mapping short keys to full names;
errors are never compacted.

`format` applies to `GET /emails/:id` and `GET /threads/:id`:

| `format` | `content.markdown` | `content.text` | `content.html` |
|---|---|---|---|
| `markdown` (default) | body | null | null |
| `full` | body | plain text | HTML |
| `raw` | null | null | HTML |

## Endpoints

| Method | Path | Key | Purpose |
|---|---|---|---|
| GET | `/emails` | member | List emails, newest first, paginated |
| GET | `/emails/:id` | member | One email with content and attachments |
| POST | `/emails/send` | admin | Send a new email, starting a thread |
| POST | `/emails/reply` | admin | Reply within a thread |
| GET | `/threads` | member | List threads, paginated |
| GET | `/threads/:id` | member | One thread with its messages, oldest first |
| POST | `/search` | member | Fulltext, semantic or hybrid search |
| GET | `/mailboxes` | member | Connected mailboxes |
| POST | `/mailboxes` | admin | Connect an IMAP mailbox |
| DELETE | `/mailboxes/:id` | admin | Disconnect a mailbox |
| GET | `/labels` | member | Labels, system and custom |
| POST | `/labels` | admin | Create a custom label |
| PATCH | `/labels/:id` | admin | Update a custom label |
| DELETE | `/labels/:id` | admin | Delete a custom label |
| GET | `/contacts` | member | The workspace contact book, paginated |
| GET | `/contacts/:id` | member | One contact |
| PATCH | `/contacts/:id` | admin | Edit a contact |
| DELETE | `/contacts/:id` | admin | Delete a contact |
| POST | `/contacts/search` | member | Semantic contact search |
| GET | `/contacts/export` | member | The contact book as CSV |
| GET | `/webhooks` | member | Webhook subscriptions |
| POST | `/webhooks` | admin | Create a subscription |
| PATCH | `/webhooks/:id` | admin | Update a subscription |
| DELETE | `/webhooks/:id` | admin | Delete a subscription |
| POST | `/webhooks/:id/test` | member | Send a test event |
| GET | `/webhooks/:id/deliveries` | member | Delivery attempts, newest first |
| GET | `/usage` | member | The current period's usage |

## Emails

**`GET /emails`**: `limit` (1 to 100, default 50), `cursor`, `date_from` and `date_to` (ISO 8601, inclusive,
on `sent_at`), `mailbox_id`, `direction` (`inbound` or `outbound`). Items are `V1EmailListItem`: a `V1Email`
without `content` and without `metadata.attachments`. The cursor pages on `sent_at` alone; see
[sync.md](sync.md) for the boundary case.

**`GET /emails/:id`**: `format`. Returns `V1Email`:

| Field | Type |
|---|---|
| `id`, `thread_id` | string |
| `from` | `{ name: string or null, email: string }` |
| `to` | array of the same |
| `subject` | string or null |
| `sent_at` | ISO timestamp |
| `direction` | `inbound` or `outbound` |
| `content` | `{ markdown, text, html }`, each string or null, per `format` |
| `ai` | `{ summary, labels: [{ name, confidence }], action, suggested_response, keywords }` |
| `metadata` | `{ message_id, mailbox_type: "imap" or "gmail", attachments: [{ filename, size }], is_draft }` |

**`POST /emails/send`** (admin): `mailbox_id`, `to` (at least one address), `subject`, `body` (plain text),
optional `cc`, `bcc`, `html_body`, `reply_to` (one address). **`POST /emails/reply`** (admin): `email_id`,
`mailbox_id`, `body`, optional `to` (overrides the default of the original sender), `cc`, `bcc`, `html_body`;
threading headers and the `Re:` subject are set for you. Both return `201` with
`{ id, thread_id, status: "sent", smtp_message_id }`, `502 smtp_error` when delivery fails and
`429 rate_limit_exceeded` at an SMTP limit. Both send real mail: [replies.md](replies.md) is the only way the
module calls them.

## Threads

**`GET /threads`**: `limit` (1 to 100, default 50), `cursor`, `search` (full text on subjects and bodies),
`date_from`, `date_to`. Items: `id`, `subject`, `participants`, `message_count`, `latest_message_at`,
`labels` (`name`, `color`, `confidence`), `ai_summary`. **`GET /threads/:id`**: `format`; adds `messages`, an
array of `V1Email` in chronological order.

## Search

**`POST /search`**: body `query` (required), `limit` (1 to 100, default 50), `mode` (`hybrid` default,
`fulltext`, `semantic`). Returns list items and `search_mode`; there is no cursor. Where semantic embeddings
are not enabled, `hybrid` and `semantic` fall back to `fulltext`. Counts towards `api_calls` and
`search_queries`.

## Mailboxes

**`GET /mailboxes`**: `id`, `type` (`imap` or `gmail`), `email`, `status`, `last_sync_at`, `sync_retries`,
`created_at`, `from_name`. **`POST /mailboxes`** (admin) connects IMAP: `host`, `port` (1 to 65535),
`username`, `password`, optional `secure` (default true), `smtp_host`, `smtp_port`, `smtp_secure`,
`smtp_username`, `smtp_password`, `from_name`. Passwords are encrypted at rest and never returned; read them
from the environment, never from a literal. Gmail is connected through Google sign-in in the console, not this
endpoint. At the plan's mailbox limit the answer is `429`. **`DELETE /mailboxes/:id`** (admin) returns
`{ id, deleted: true }`.

## Labels

**`GET /labels`**: `id`, `name`, `color`, `is_system`, `is_enabled`, `prompt`, in display order.
**`POST /labels`** (admin): `name` (up to 50 characters), `color` (six-digit hex such as `#3B82F6`),
optional `prompt` that instructs the classifier; `409 duplicate` when the name exists. **`PATCH /labels/:id`**
(admin): `name`, `color`, `prompt` (up to 20,000 characters). **`DELETE /labels/:id`** (admin): `204`.
System labels answer `403 forbidden` to both.

## Contacts

A contact book InboxParse builds from processed mail: `full_name`, `primary_email`, `emails`, `phones`,
`addresses`, `company`, `memo`, `mention_count`, `first_seen_at`, `last_seen_at`. Every field is generated
from email content and is untrusted ([untrusted-content.md](untrusted-content.md)).

**`GET /contacts`**: `limit` (1 to 200, default 50), `cursor`, `q` (substring on name, primary email and
company), newest activity first. **`PATCH /contacts/:id`** (admin): `full_name`, `memo` (up to 280
characters), `company`, `phones`, `addresses`. **`DELETE /contacts/:id`** (admin): `204`.
**`POST /contacts/search`**: `query`, `limit` (1 to 100, default 20), `threshold` (0 to 1, default 0.5);
returns a `similarity` per contact and `mode` (`semantic`, or `keyword` when embeddings are unavailable).
**`GET /contacts/export`** streams CSV.

## Webhooks

**`GET /webhooks`**: `id`, `url`, `events`, `is_active`, `auth_type`, `failure_count`, `last_failure_at`,
`last_success_at`, `disabled_at`, `created_at`; never the secret. **`POST /webhooks`** (admin): `url`
(HTTP or HTTPS), `events` (from `email.received`, `email.sent`, `email.ai_processed`, `mailbox.synced`,
`mailbox.error`), optional `secret` (generated as `whsec_...` when omitted and returned once), `auth_type`
(`none` default, `bearer`, `basic`, `header`) and `auth_config`. **`PATCH /webhooks/:id`** (admin): any of
those and `is_active`; `is_active: true` resets the failure count. **`DELETE /webhooks/:id`** (admin).
**`POST /webhooks/:id/test`** returns `{ success, delivery: { id, status, response_status, error_message,
delivered_at } }`. **`GET /webhooks/:id/deliveries`**: `status` (`pending`, `delivered`, `failed`), `limit`
(1 to 100, default 50), `offset`; returns `{ data, total, hasMore }`. Delivery behaviour is in
[webhooks.md](webhooks.md).

## Usage

**`GET /usage`**: `period_start`, `period_end`, `api_calls`, `search_queries`, `emails_synced`,
`emails_processed`, `webhook_deliveries` for the current calendar month.

## MCP server

`https://inboxparse.com/api/mcp` exposes the same API as tools to MCP clients, authorised with OAuth 2.1 and
PKCE instead of an API key. It serves an assistant reading a mailbox for a person; this module serves an app.
