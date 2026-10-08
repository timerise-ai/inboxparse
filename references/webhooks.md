# Webhooks

How InboxParse delivers events, how to register a subscription, and the receiver route. It assumes the client
of [client.md](client.md) and the store seam of [adaptation.md](adaptation.md).

## What a delivery is

InboxParse sends each event as an HTTP `POST` with a JSON body:

```json
{ "event": "email.received", "timestamp": "2026-10-08T12:00:00.000Z", "data": { "messageId": "..." } }
```

| Header | Value |
|---|---|
| `Content-Type` | `application/json` |
| `User-Agent` | `InboxParse/1.0` |
| `X-InboxParse-Signature` | `sha256=` followed by the hex HMAC-SHA256 of the exact body, keyed by the subscription secret |
| `Authorization` or a custom header | Only when the subscription sets `auth_type` to `bearer`, `basic` or `header`, in addition to the signature |

The `data` of the two email events:

| Event | `data` |
|---|---|
| `email.received` | `messageId`, `threadId`, `direction` (`inbound` or `outbound`), `hasAttachments`, optional `length` |
| `email.ai_processed` | `messageId`, `labelId`, `labelName`: one delivery per label applied |
| `test` | `message`, `webhook_id`: sent by `POST /webhooks/:id/test` |

`email.sent`, `mailbox.synced` and `mailbox.error` are accepted when subscribing; the receiver below
acknowledges them without acting. **A delivery carries identifiers, never the email**: `messageId` is the
`id` that `GET /emails/:id` takes.

Delivery behaviour, checked against the InboxParse implementation:

- One attempt is made as the event happens, with a **10-second timeout**. Any 2xx is success.
- A failed delivery is retried by a scheduled job **up to 5 attempts** in all. The retry sends the stored
  payload, so `timestamp` is the same on every attempt.
- **10 failures in a row disable the subscription** (`is_active: false`, `disabled_at` set). A success
  resets the count. `PATCH /webhooks/:id` with `is_active: true` re-enables it and resets the count.
- The signature covers the body only. There is no delivery id header and no signed timestamp, so a captured
  delivery verifies again if replayed.

That last point and the first one decide the receiver's shape: it verifies, then uses only the `messageId`,
and fetches the email from the API with its own key. A replayed delivery can then cause nothing but a
refetch of an email the workspace already has, and the slow part runs after the response, inside the
10 seconds.

## Registering the subscription

Once, with the admin key, from a shell (`assets/examples/setup-webhook.sh`) or the console:

| Field | Value |
|---|---|
| `url` | `https://<host>/api/inboxparse/webhook` |
| `events` | `["email.received", "email.ai_processed"]` |
| `secret` | Omit it: InboxParse generates a `whsec_` secret |

The `201` response holds `data.secret` **once**; no later call returns it. Store it as
`INBOXPARSE_WEBHOOK_SECRET` in the host's environment and nowhere else. To rotate, `PATCH /webhooks/:id` with
a new `secret`, then update the variable. For local development, expose the dev server through a tunnel and
register that URL as a second subscription, so the production secret never leaves production.

## Signature

```ts
// lib/inboxparse/signature.ts
import { createHmac, timingSafeEqual } from "node:crypto";

export const SIGNATURE_HEADER = "x-inboxparse-signature";

// InboxParse signs the exact request body: "sha256=" + hex(HMAC-SHA256(secret, body)).
export function verifySignature(rawBody: string, header: string | null, secret: string): boolean {
  if (!header?.startsWith("sha256=")) return false;
  const expected = Buffer.from(createHmac("sha256", secret).update(rawBody).digest("hex"), "utf8");
  const received = Buffer.from(header.slice("sha256=".length), "utf8");
  return received.length === expected.length && timingSafeEqual(received, expected);
}
```

The comparison is constant-time and length-checked first, since `timingSafeEqual` throws on unequal lengths.
The body must be the string read from the request before any parsing: `JSON.stringify(JSON.parse(body))` is
not the same bytes, and the suite in [testing.md](testing.md) holds that a whitespace change fails.

## Receiver route

```ts
// app/api/inboxparse/webhook/route.ts
import { after } from "next/server";
import { ingestEmail } from "@/lib/inboxparse/ingest";
import { inboxStore } from "@/lib/inboxparse/instance";
import { SIGNATURE_HEADER, verifySignature } from "@/lib/inboxparse/signature";
import type { WebhookEvent } from "@/lib/inboxparse/types";

export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  const secret = process.env.INBOXPARSE_WEBHOOK_SECRET;
  if (!secret) return new Response("Webhook secret not configured", { status: 500 });

  // Read the bytes InboxParse signed before anything parses them.
  const rawBody = await request.text();
  if (!verifySignature(rawBody, request.headers.get(SIGNATURE_HEADER), secret)) {
    return new Response("Invalid signature", { status: 401 });
  }

  let event: WebhookEvent;
  try {
    event = JSON.parse(rawBody) as WebhookEvent;
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  if (event.event === "email.received" || event.event === "email.ai_processed") {
    const messageId = event.data.messageId;
    // A label arriving later means the stored copy is stale, so fetch it again.
    const refresh = event.event === "email.ai_processed";
    // Acknowledge first: the fetch runs after the response, and the sync cron
    // picks up anything this delivery fails to fetch.
    after(async () => {
      try {
        await ingestEmail(inboxStore, messageId, { refresh });
      } catch (error) {
        console.error("[inboxparse] webhook ingest failed", { messageId, error: String(error) });
      }
    });
  }

  return new Response(null, { status: 204 });
}
```

- **`request.text()` comes first.** Next.js App Router hands the route the raw body; nothing parses it before
  the signature is checked.
- **`401` for a bad signature, `204` for everything verified**, including events the module ignores. A `4xx`
  or `5xx` to a verified delivery only counts towards the 10 failures that disable the subscription.
- **`after()` runs the fetch once the response is sent.** If it fails, the email is still caught by the next
  run of the sync in [sync.md](sync.md); nothing here retries.
- **`email.ai_processed` refetches.** The stored copy may predate a label, so `refresh: true` replaces it;
  `onNewEmail` still runs only once per email, on the call that created it.
- **No event is the only path.** Treat each delivery as a hint that makes an email arrive sooner; the sync is
  what guarantees it arrives.
