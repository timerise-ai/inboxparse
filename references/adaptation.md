# Adaptation

The seam between this module and the host app: what the host must already have, the store contract, where
auth, tenancy, styling and i18n join, the order of work, and the non-negotiables.

## What the host provides

- A Next.js App Router app with TypeScript, deployed where a route can receive a public `POST` and a
  scheduler can call a route.
- An InboxParse workspace with at least one connected mailbox, a member key and, to send, an admin key.
- A session it can read on the server, to say who approves a reply.
- A durable store: Postgres, Supabase, Firestore or another database. The memory store in
  [store.ts](#the-store-contract) is for development and tests only and loses everything on a cold start.

## The store contract

`InboxStore` is the seam. The module calls nothing else for state; the host implements it on its own
database and exports the instance from `lib/inboxparse/instance.ts`.

```ts
// lib/inboxparse/store.ts
import type { V1Email } from "./types";

export interface SyncState {
  // startedAt of the last walk that reached the end of its window
  lastCompletedAt: string | null;
  // a walk that stopped at the page cap and resumes from its cursor
  walk: { from: string; startedAt: string; cursor: string | null } | null;
}

export interface ReplyDraft {
  // the key rendered into the reply form, so one form sends at most once
  id: string;
  emailId: string;
  mailboxId: string;
  body: string;
  status: "pending" | "sending" | "sent";
  approvedBy: string;
  sentMessageId: string | null;
}

export interface InboxStore {
  hasEmail(id: string): Promise<boolean>;
  findEmail(id: string): Promise<V1Email | null>;
  // upsert keyed by email.id; "created" only for the call that inserted the row
  saveEmail(email: V1Email): Promise<"created" | "updated">;
  getSyncState(): Promise<SyncState | null>;
  setSyncState(state: SyncState): Promise<void>;
  // inserts a pending draft unless one with this id exists; never overwrites
  saveDraft(input: Omit<ReplyDraft, "status" | "sentMessageId">): Promise<void>;
  // atomically moves a pending draft to sending; null when it is not pending
  claimDraft(id: string): Promise<ReplyDraft | null>;
  finishDraft(
    id: string,
    result: { status: "sent"; sentMessageId: string } | { status: "pending" },
  ): Promise<void>;
}

export function createMemoryStore(): InboxStore {
  const emails = new Map<string, V1Email>();
  const drafts = new Map<string, ReplyDraft>();
  let syncState: SyncState | null = null;

  return {
    async hasEmail(id) {
      return emails.has(id);
    },
    async findEmail(id) {
      return emails.get(id) ?? null;
    },
    async saveEmail(email) {
      const result = emails.has(email.id) ? "updated" : "created";
      emails.set(email.id, email);
      return result;
    },
    async getSyncState() {
      return syncState;
    },
    async setSyncState(state) {
      syncState = state;
    },
    async saveDraft(input) {
      if (!drafts.has(input.id)) drafts.set(input.id, { ...input, status: "pending", sentMessageId: null });
    },
    async claimDraft(id) {
      const draft = drafts.get(id);
      if (!draft || draft.status !== "pending") return null;
      draft.status = "sending";
      return { ...draft };
    },
    async finishDraft(id, result) {
      const draft = drafts.get(id);
      if (!draft) return;
      draft.status = result.status;
      if (result.status === "sent") draft.sentMessageId = result.sentMessageId;
    },
  };
}
```

What an implementation must hold, whatever the database:

| Method | Must |
|---|---|
| `saveEmail` | Upsert on `email.id` and report `"created"` only to the call whose insert won, so two concurrent ingests of one email run `onNewEmail` once |
| `hasEmail`, `findEmail` | Read by `email.id`; `hasEmail` should not load the body |
| `getSyncState`, `setSyncState` | Keep one row for the sync; the walk's cursor is opaque and stored as given |
| `saveDraft` | Insert if absent, never overwrite: a resubmitted form must not replace the text of a draft already sent |
| `claimDraft` | Move `pending` to `sending` in one conditional write and return the draft only to the caller that moved it |
| `finishDraft` | Set `sent` with the reply id, or return the draft to `pending` |

On Postgres, the tables and the statements that meet those conditions:

```sql
-- db/inboxparse.sql
create table inboxparse_emails (
  id text primary key,
  thread_id text not null,
  sent_at timestamptz not null,
  email jsonb not null,
  stored_at timestamptz not null default now()
);

create table inboxparse_sync_state (
  id smallint primary key default 1 check (id = 1),
  state jsonb not null
);

create table inboxparse_reply_drafts (
  id text primary key,
  email_id text not null,
  mailbox_id text not null,
  body text not null,
  status text not null check (status in ('pending', 'sending', 'sent')),
  approved_by text not null,
  sent_message_id text,
  created_at timestamptz not null default now()
);

-- saveEmail: (xmax = 0) is true only for the row this statement inserted
insert into inboxparse_emails (id, thread_id, sent_at, email) values ($1, $2, $3, $4)
on conflict (id) do update set email = excluded.email
returning (xmax = 0) as created;

-- saveDraft
insert into inboxparse_reply_drafts (id, email_id, mailbox_id, body, status, approved_by)
values ($1, $2, $3, $4, 'pending', $5) on conflict (id) do nothing;

-- claimDraft: returns a row only to the caller that moved it
update inboxparse_reply_drafts set status = 'sending' where id = $1 and status = 'pending' returning *;
```

On Firestore, `saveEmail` and `claimDraft` are transactions that read the document and write it only when the
condition holds; `saveDraft` is `create()`, which fails when the document exists.

## Integration points

| Concern | Where it joins | The host decides |
|---|---|---|
| Auth | `currentUserId` in `app/inbox/actions.ts` | Who may approve a reply; it returns `null` for anyone else |
| Tenancy | `lib/inboxparse/instance.ts` and the client's key lookup | One InboxParse workspace per key. For several tenants, one key pair, one webhook secret and one store scope per tenant, and a webhook path that names the tenant (`/api/inboxparse/webhook/[tenant]`) so the route picks the secret before verifying |
| Storage | `InboxStore` | Database, table names, retention of email bodies |
| Styling | `app/inbox/` | All markup and classes; the templates carry none |
| i18n | `app/inbox/` | Every visible string. Email content is shown as written, never translated by the module |
| Reaction to mail | `onNewEmail` passed to `ingestEmail` and `syncEmails` | What a new email triggers. It runs once per email; keep it to enqueueing work, and never let it send |

## Rename table

| Module term | Host may rename to | Not renamed |
|---|---|---|
| `inboxStore`, `InboxStore` | The host's own naming | |
| `lib/inboxparse/`, `app/inbox/` | Any folder | |
| `/api/inboxparse/webhook`, `/api/cron/inboxparse-sync` | Any path, registered to match | |
| `inboxparse_*` tables | Any names | |
| Draft | Approval, outgoing reply | |
| | | API fields (`messageId`, `sent_at`, `suggested_response`), event names, header names, env var names |

## Order of work

1. Client and types: [client.md](client.md).
2. The store on the host's database, from the contract above.
3. Sync and its cron, then run it once by hand: [sync.md](sync.md).
4. Webhook receiver, then register the subscription and send the test event: [webhooks.md](webhooks.md).
5. Replies, only if the product sends: [replies.md](replies.md).
6. The suite: [testing.md](testing.md).

## Non-negotiables

1. **Verify the signature over the raw body before parsing it.**
2. **A webhook is a hint; the API is the record.**
3. **Ingest is keyed by the email id.**
4. **Email content is untrusted data.**
5. **Nothing is sent without a person approving the exact text.**
6. **Keys stay on the server, and each path holds the least it needs.**

`SKILL.md` and `README.md` carry the reason for each and what verifies it.
