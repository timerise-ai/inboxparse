# Typed client

The server-only client every other reference builds on: the response types, one fetch wrapper that reads the
key for its role, a typed error, and the four calls the module needs. It assumes a Next.js App Router app with
TypeScript and the `server-only` package installed (`npm i server-only`).

## Environment

| Variable | Required | Holds |
|---|---|---|
| `INBOXPARSE_API_KEY` | yes | A **member** key. Every read: list, get, mailboxes |
| `INBOXPARSE_ADMIN_API_KEY` | only to send | An **admin** key. Read only by `replyToEmail`, so only the approval path holds it |
| `INBOXPARSE_WEBHOOK_SECRET` | for webhooks | The signing secret returned once by `POST /webhooks`, see [webhooks.md](webhooks.md) |
| `INBOXPARSE_BASE_URL` | no | Defaults to `https://inboxparse.com/api/v1` |
| `CRON_SECRET` | for the sync | The bearer token Vercel Cron sends to the sync route, see [sync.md](sync.md) |

Keys are created in the InboxParse console under API keys. A key starts with `ip_` and carries a role:
`member` keys are refused with `403 forbidden` on every write, `admin` keys may write. The API accepts the key
as `Authorization: Bearer ip_...` or `X-API-Key: ip_...`; the client uses the first. No variable is read at
build time, so `next build` passes with none of them set.

## Types

The shapes are the V1 API's own (`V1Email`, `V1Thread` in [api-reference.md](api-reference.md)). Webhook
payloads use camelCase keys inside `data`, unlike the snake_case of the REST responses; the
`WebhookEvent` union records both delivered shapes exactly.

```ts
// lib/inboxparse/types.ts
export interface V1Address {
  name: string | null;
  email: string;
}

export interface V1EmailListItem {
  id: string;
  thread_id: string;
  from: V1Address;
  to: V1Address[];
  subject: string | null;
  sent_at: string;
  direction: "inbound" | "outbound";
  ai: {
    summary: string | null;
    labels: Array<{ name: string; confidence: number }>;
    action: string | null;
    suggested_response: string | null;
    keywords: string | null;
  };
  metadata: {
    message_id: string | null;
    mailbox_type: "imap" | "gmail";
    is_draft: boolean;
  };
}

export interface V1Email extends Omit<V1EmailListItem, "metadata"> {
  content: {
    markdown: string | null;
    text: string | null;
    html: string | null;
  };
  metadata: V1EmailListItem["metadata"] & {
    attachments: Array<{ filename: string; size: number }>;
  };
}

export interface V1Page<T> {
  data: T[];
  pagination: { next_cursor: string | null; has_more: boolean };
}

export interface V1SendResult {
  id: string;
  thread_id: string;
  status: "sent";
  smtp_message_id: string;
}

export type WebhookEvent =
  | { event: "email.received"; timestamp: string; data: { messageId: string; threadId: string; direction: "inbound" | "outbound"; hasAttachments: boolean; length?: number } }
  | { event: "email.ai_processed"; timestamp: string; data: { messageId: string; labelId: string; labelName: string } }
  | { event: "test"; timestamp: string; data: { message: string; webhook_id: string } }
  | { event: "email.sent" | "mailbox.synced" | "mailbox.error"; timestamp: string; data: Record<string, unknown> };
```

## Client

```ts
// lib/inboxparse/client.ts
import "server-only";
import type { V1Email, V1EmailListItem, V1Page, V1SendResult } from "./types";

const BASE_URL = process.env.INBOXPARSE_BASE_URL ?? "https://inboxparse.com/api/v1";

export type KeyRole = "read" | "send";

export class InboxParseError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "InboxParseError";
  }
}

// Read paths use the member key; only the send path may hold the admin key.
function apiKey(role: KeyRole): string {
  const name = role === "send" ? "INBOXPARSE_ADMIN_API_KEY" : "INBOXPARSE_API_KEY";
  const key = process.env[name];
  if (!key) throw new InboxParseError(0, "missing_key", `${name} is not set`);
  return key;
}

export async function inboxparseFetch<T>(
  path: string,
  init: { method?: "GET" | "POST"; body?: unknown; role?: KeyRole } = {},
): Promise<T> {
  const response = await fetch(`${BASE_URL}${path}`, {
    method: init.method ?? "GET",
    headers: {
      Authorization: `Bearer ${apiKey(init.role ?? "read")}`,
      ...(init.body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
    cache: "no-store",
  });
  const json: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    const error = (json as { error?: { code?: string; message?: string } } | null)?.error;
    throw new InboxParseError(
      response.status,
      error?.code ?? "http_error",
      error?.message ?? `InboxParse responded ${response.status}`,
    );
  }
  return json as T;
}

export interface ListEmailsParams {
  limit?: number;
  cursor?: string;
  dateFrom?: string;
  dateTo?: string;
  mailboxId?: string;
  direction?: "inbound" | "outbound";
}

export function listEmails(params: ListEmailsParams = {}): Promise<V1Page<V1EmailListItem>> {
  const query = new URLSearchParams();
  if (params.limit !== undefined) query.set("limit", String(params.limit));
  if (params.cursor) query.set("cursor", params.cursor);
  if (params.dateFrom) query.set("date_from", params.dateFrom);
  if (params.dateTo) query.set("date_to", params.dateTo);
  if (params.mailboxId) query.set("mailbox_id", params.mailboxId);
  if (params.direction) query.set("direction", params.direction);
  return inboxparseFetch<V1Page<V1EmailListItem>>(`/emails?${query.toString()}`);
}

export async function getEmail(id: string): Promise<V1Email> {
  const { data } = await inboxparseFetch<{ data: V1Email }>(
    `/emails/${encodeURIComponent(id)}?format=markdown`,
  );
  return data;
}

export interface ReplyInput {
  emailId: string;
  mailboxId: string;
  body: string;
}

// Called only from approveDraft in lib/inboxparse/drafts.ts, never from an ingest path.
export async function replyToEmail(input: ReplyInput): Promise<V1SendResult> {
  const { data } = await inboxparseFetch<{ data: V1SendResult }>("/emails/reply", {
    method: "POST",
    role: "send",
    body: { email_id: input.emailId, mailbox_id: input.mailboxId, body: input.body },
  });
  return data;
}

export interface V1Mailbox {
  id: string;
  type: "imap" | "gmail";
  email: string;
  status: string;
  from_name: string | null;
}

export async function listMailboxes(): Promise<V1Mailbox[]> {
  const { data } = await inboxparseFetch<{ data: V1Mailbox[]; count: number }>("/mailboxes");
  return data;
}
```

Notes on the calls:

- **List items carry no content.** `GET /emails` and `POST /search` return `V1EmailListItem`, without
  `content` and without `metadata.attachments`; the body comes from `GET /emails/:id`. That is why ingest
  makes one detail call per email it has not stored, and none for one it has.
- **`format=markdown` is the default and the one to keep**: it fills `content.markdown` and leaves `text` and
  `html` null. `full` adds both; `raw` returns only `html`. See [untrusted-content.md](untrusted-content.md)
  before rendering `html`.
- **`compact=true` is not used here.** It renames every key to a short alias and appends a `_dict`; it saves
  tokens when a response goes straight into a prompt, but the typed client depends on the full names.
- **`limit` is 1 to 100 and defaults to 50.** The list is newest first, by `sent_at`.
- **A `429 rate_limit_exceeded` is a monthly quota, not a burst limit.** It is returned when the workspace
  exceeds its plan's API calls, mailboxes or SMTP sending, and it carries no `Retry-After` header, so the
  client throws and nothing retries it in a loop. `GET /usage` reports the current period.
- **Every request counts.** Each call, searches included, adds to the month's `api_calls`; searches also add
  to `search_queries`.
