# Sync

The scheduled poll that makes the store complete whether or not a webhook arrived. It assumes the client of
[client.md](client.md) and the store seam of [adaptation.md](adaptation.md).

## Why a poll

A webhook makes an email arrive sooner; it does not prove that every email arrives. A delivery can time out,
exhaust its five attempts, or reach a subscription that ten failures disabled, and the receiver's own fetch
can fail after it has answered. The sync walks the list endpoint on a schedule and stores whatever the store
lacks, so the store converges on the API whatever happened to the deliveries.

## The window

Mail reaches InboxParse after it was sent: a mailbox syncs on its own schedule and processing follows, so an
email's `sent_at` can be hours older than the moment it becomes listable. A cursor on the newest `sent_at`
seen would step past it. The sync re-reads a **48-hour lookback** instead:

- A walk lists `GET /emails?date_from=<from>` newest first, where `from` is 48 hours before the start of the
  last walk that completed, or before now on the first run. After downtime the window therefore reaches back
  to where the last complete walk began, not only 48 hours.
- For each item the store lacks, one `GET /emails/:id`; an item it has costs nothing more. Overlap between
  windows is free beyond the list call.
- **The list cursor pages on `sent_at` alone**, strictly older than the last item. Emails sharing the
  boundary timestamp would fall between pages, so whenever a page has more after it, the sync also lists
  that exact timestamp (`date_from` and `date_to` both set to it) before moving on.
- **A run stops after 10 pages** (1,000 emails) to stay inside the function's time limit, and saves the walk
  with its cursor. The next run resumes that walk instead of restarting at the newest page, which a backlog
  larger than one run would otherwise never get past.

Mail older than the window, such as an archive backfill of a newly connected mailbox, is outside it. Import
it once by running the walk with `date_from` set to the start of the archive.

```ts
// lib/inboxparse/ingest.ts
import "server-only";
import { getEmail, listEmails } from "./client";
import type { InboxStore, SyncState } from "./store";
import type { V1Email, V1EmailListItem } from "./types";

export const SYNC_LOOKBACK_MS = 48 * 60 * 60 * 1000;
export const SYNC_PAGE_LIMIT = 100;
export const SYNC_MAX_PAGES = 10;

export interface IngestOptions {
  onNewEmail?: (email: V1Email) => Promise<void>;
}

// One detail fetch per email the store has never seen, unless `refresh` asks for the
// newest copy. onNewEmail runs only for the call whose upsert created the row.
export async function ingestEmail(
  store: InboxStore,
  id: string,
  options: IngestOptions & { refresh?: boolean } = {},
): Promise<"created" | "updated" | "existing"> {
  if (!options.refresh && (await store.hasEmail(id))) return "existing";
  const email = await getEmail(id);
  const result = await store.saveEmail(email);
  if (result === "created") await options.onNewEmail?.(email);
  return result;
}

// The list cursor pages on sent_at alone, so emails sharing the boundary timestamp
// are fetched with an exact date_from/date_to query before the next page.
async function sameTimestamp(sentAt: string): Promise<V1EmailListItem[]> {
  const page = await listEmails({ dateFrom: sentAt, dateTo: sentAt, limit: SYNC_PAGE_LIMIT });
  return page.data;
}

export interface SyncResult {
  created: number;
  pages: number;
  complete: boolean;
}

export async function syncEmails(
  store: InboxStore,
  options: IngestOptions & { now?: Date } = {},
): Promise<SyncResult> {
  const now = options.now ?? new Date();
  const state: SyncState = (await store.getSyncState()) ?? { lastCompletedAt: null, walk: null };
  const base = state.lastCompletedAt ? new Date(state.lastCompletedAt) : now;
  const walk = state.walk ?? {
    from: new Date(base.getTime() - SYNC_LOOKBACK_MS).toISOString(),
    startedAt: now.toISOString(),
    cursor: null,
  };

  let created = 0;
  for (let pages = 1; pages <= SYNC_MAX_PAGES; pages++) {
    const page = await listEmails({
      dateFrom: walk.from,
      limit: SYNC_PAGE_LIMIT,
      ...(walk.cursor ? { cursor: walk.cursor } : {}),
    });
    const items = [...page.data];
    const last = page.data.at(-1);
    if (page.pagination.has_more && last) items.push(...(await sameTimestamp(last.sent_at)));

    for (const item of items) {
      if ((await ingestEmail(store, item.id, options)) === "created") created++;
    }

    if (!page.pagination.has_more || !page.pagination.next_cursor) {
      await store.setSyncState({ lastCompletedAt: walk.startedAt, walk: null });
      return { created, pages, complete: true };
    }
    walk.cursor = page.pagination.next_cursor;
  }

  await store.setSyncState({ lastCompletedAt: state.lastCompletedAt, walk });
  return { created, pages: SYNC_MAX_PAGES, complete: false };
}
```

`SYNC_LOOKBACK_MS`, `SYNC_PAGE_LIMIT` and `SYNC_MAX_PAGES` are design parameters: widen the lookback for
mailboxes that sync rarely, never shrink the page limit below the API's maximum of 100.

## Store instance

```ts
// lib/inboxparse/instance.ts
import "server-only";
import { createMemoryStore, type InboxStore } from "./store";

// Replace with the host's adapter (see references/adaptation.md). The memory store
// loses its state on every cold start and is for development and tests only.
export const inboxStore: InboxStore = createMemoryStore();
```

## Cron route

```ts
// app/api/cron/inboxparse-sync/route.ts
import { timingSafeEqual } from "node:crypto";
import { syncEmails } from "@/lib/inboxparse/ingest";
import { inboxStore } from "@/lib/inboxparse/instance";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

function authorized(request: Request): boolean {
  const secret = process.env.CRON_SECRET;
  const header = request.headers.get("authorization");
  if (!secret || !header) return false;
  const expected = Buffer.from(`Bearer ${secret}`);
  const received = Buffer.from(header);
  return received.length === expected.length && timingSafeEqual(received, expected);
}

export async function GET(request: Request): Promise<Response> {
  if (!authorized(request)) return new Response("Unauthorized", { status: 401 });
  const result = await syncEmails(inboxStore);
  return Response.json(result);
}
```

Schedule it in `vercel.json`:

```json
{ "crons": [{ "path": "/api/cron/inboxparse-sync", "schedule": "*/15 * * * *" }] }
```

Vercel Cron sends `Authorization: Bearer <CRON_SECRET>` when the project has
`CRON_SECRET` set; the route refuses anything else. Vercel plans limit how often a cron may run, so check the
plan before choosing the schedule, and on a host without Vercel Cron call the same route from any scheduler
that can send the header.

## Cost

Each run spends one list call, one more per extra page and per boundary check, and one detail call per new
email. A quarter-hourly schedule spends about 2,900 list calls a month before it fetches any email. Size the
schedule to the plan's monthly API-call limit, which `GET /usage` reports against.
