# Testing

The suite carried into the generated app: 17 tests in four files, run with Vitest against an in-process fake
of the V1 API, with no network and no keys. It assumes every file of [client.md](client.md),
[webhooks.md](webhooks.md), [sync.md](sync.md) and [replies.md](replies.md).

## Setup

```bash
npm i -D vitest
npm pkg set scripts.test="vitest run"
```

```ts
// vitest.config.ts
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./", import.meta.url)),
      // server-only throws outside the react-server condition; the tests run in plain Node
      "server-only": fileURLToPath(new URL("./tests/inboxparse/server-only-stub.ts", import.meta.url)),
    },
  },
  test: { include: ["tests/**/*.test.ts"], environment: "node" },
});
```

```ts
// tests/inboxparse/server-only-stub.ts
export {};
```

## Fake API

The fake answers the five calls the module makes with the V1 semantics that matter here: newest first,
inclusive `date_from` and `date_to`, a cursor strictly older than the last item's `sent_at`, list items
without content, and an SMTP failure on demand.

```ts
// tests/inboxparse/fake-api.ts
import { vi } from "vitest";
import type { V1Email } from "@/lib/inboxparse/types";

export function email(id: string, sentAt: string, suggested: string | null = null): V1Email {
  return {
    id,
    thread_id: `t-${id}`,
    from: { name: "Sender", email: "sender@example.com" },
    to: [{ name: null, email: "inbox@example.com" }],
    subject: `Subject ${id}`,
    sent_at: sentAt,
    direction: "inbound",
    content: { markdown: `Body ${id}`, text: null, html: null },
    ai: { summary: null, labels: [], action: null, suggested_response: suggested, keywords: null },
    metadata: { message_id: null, mailbox_type: "imap", attachments: [], is_draft: false },
  };
}

export interface FakeApi {
  calls: Array<{ method: string; path: string; auth: string | null; body: unknown }>;
  emails: V1Email[];
  failReply: boolean;
}

// Mirrors the V1 list semantics: newest first, date_from/date_to inclusive on sent_at,
// and a cursor that pages on sent_at alone (strictly older than the last item).
export function installFakeApi(emails: V1Email[]): FakeApi {
  const api: FakeApi = { calls: [], emails, failReply: false };
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: string | URL, init?: RequestInit) => {
      const url = new URL(String(input));
      const path = url.pathname.replace("/api/v1", "");
      const method = init?.method ?? "GET";
      const headers = new Headers(init?.headers);
      const body: unknown = init?.body ? JSON.parse(String(init.body)) : undefined;
      api.calls.push({ method, path, auth: headers.get("authorization"), body });

      if (method === "GET" && path === "/emails") {
        const limit = Number(url.searchParams.get("limit") ?? 50);
        const from = url.searchParams.get("date_from");
        const to = url.searchParams.get("date_to");
        const cursor = url.searchParams.get("cursor");
        const before = cursor ? (JSON.parse(Buffer.from(cursor, "base64").toString()) as { sent_at: string }).sent_at : null;
        const rows = [...api.emails]
          .sort((a, b) => b.sent_at.localeCompare(a.sent_at))
          .filter((e) => (!from || e.sent_at >= from) && (!to || e.sent_at <= to) && (!before || e.sent_at < before));
        const page = rows.slice(0, limit);
        const hasMore = rows.length > limit;
        const last = page.at(-1);
        return Response.json({
          // list items carry no content and no attachments
          data: page.map(({ content, metadata: { attachments, ...metadata }, ...item }) => {
            void content;
            void attachments;
            return { ...item, metadata };
          }),
          pagination: {
            next_cursor: hasMore && last ? Buffer.from(JSON.stringify({ sent_at: last.sent_at })).toString("base64") : null,
            has_more: hasMore,
          },
        });
      }
      const detail = /^\/emails\/([^/]+)$/.exec(path);
      if (method === "GET" && detail && detail[1] !== "send" && detail[1] !== "reply") {
        const found = api.emails.find((e) => e.id === decodeURIComponent(detail[1] ?? ""));
        return found
          ? Response.json({ data: found })
          : Response.json({ error: { message: "Email not found", code: "not_found" } }, { status: 404 });
      }
      if (method === "POST" && path === "/emails/reply") {
        if (api.failReply) return Response.json({ error: { message: "SMTP failed", code: "smtp_error" } }, { status: 502 });
        return Response.json({ data: { id: `sent-${api.calls.length}`, thread_id: "t", status: "sent", smtp_message_id: "m" } }, { status: 201 });
      }
      return Response.json({ error: { message: "Not found", code: "not_found" } }, { status: 404 });
    }),
  );
  return api;
}
```

## What the suite holds

| File | Holds |
|---|---|
| `signature.test.ts` | The signature verifies over the raw body only: a re-serialised body, another secret, a missing prefix and a truncated digest all fail |
| `webhook.test.ts` | An unsigned or wrongly signed delivery gets `401` and fetches nothing; a retried delivery fetches the email once; the test event gets `204` without an API call |
| `ingest.test.ts` | One detail fetch per new email, `onNewEmail` once, reads on the member key, every email across pages, the boundary-timestamp emails kept, a capped walk resumed, the window after downtime |
| `drafts.test.ts` | Two concurrent approvals of one form send one reply, with the admin key and the submitted text; an empty body sends nothing; a failed send can be resubmitted |

```ts
// tests/inboxparse/signature.test.ts
import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { verifySignature } from "@/lib/inboxparse/signature";

const secret = "whsec_test";
const body = JSON.stringify({ event: "email.received", timestamp: "2026-10-08T12:00:00.000Z", data: { messageId: "m1" } });
const sign = (raw: string, key = secret) => `sha256=${createHmac("sha256", key).update(raw).digest("hex")}`;

describe("verifySignature", () => {
  it("accepts the signature InboxParse computes over the raw body", () => {
    expect(verifySignature(body, sign(body), secret)).toBe(true);
  });
  it("rejects a body changed after signing, even by whitespace", () => {
    expect(verifySignature(JSON.stringify(JSON.parse(body), null, 2), sign(body), secret)).toBe(false);
  });
  it("rejects a signature made with another secret", () => {
    expect(verifySignature(body, sign(body, "whsec_other"), secret)).toBe(false);
  });
  it("rejects a missing header, a header without the sha256= prefix and a truncated digest", () => {
    expect(verifySignature(body, null, secret)).toBe(false);
    expect(verifySignature(body, sign(body).slice("sha256=".length), secret)).toBe(false);
    expect(verifySignature(body, sign(body).slice(0, -2), secret)).toBe(false);
  });
});
```

```ts
// tests/inboxparse/webhook.test.ts
import { createHmac } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { email, installFakeApi } from "./fake-api";

const pending: Array<Promise<unknown>> = [];
vi.mock("next/server", () => ({
  after: (task: () => Promise<unknown>) => {
    pending.push(task());
  },
}));

const secret = "whsec_test";
const sign = (raw: string) => `sha256=${createHmac("sha256", secret).update(raw).digest("hex")}`;
const post = (raw: string, signature: string | null) =>
  new Request("http://localhost/api/inboxparse/webhook", {
    method: "POST",
    body: raw,
    headers: signature ? { "x-inboxparse-signature": signature } : {},
  });

beforeEach(() => {
  vi.stubEnv("INBOXPARSE_WEBHOOK_SECRET", secret);
  vi.stubEnv("INBOXPARSE_API_KEY", "ip_member");
  pending.length = 0;
});
afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.resetModules();
});

describe("POST /api/inboxparse/webhook", () => {
  it("answers 401 to an unsigned or wrongly signed delivery and fetches nothing", async () => {
    const api = installFakeApi([email("m1", "2026-10-08T11:00:00.000Z")]);
    const { POST } = await import("@/app/api/inboxparse/webhook/route");
    const raw = JSON.stringify({ event: "email.received", timestamp: "t", data: { messageId: "m1" } });
    expect((await POST(post(raw, null))).status).toBe(401);
    expect((await POST(post(raw, sign(`${raw} `)))).status).toBe(401);
    expect(api.calls).toHaveLength(0);
  });
  it("acknowledges a signed delivery and stores the email by its id, once across retries", async () => {
    const api = installFakeApi([email("m1", "2026-10-08T11:00:00.000Z")]);
    const { POST } = await import("@/app/api/inboxparse/webhook/route");
    const { inboxStore } = await import("@/lib/inboxparse/instance");
    const raw = JSON.stringify({ event: "email.received", timestamp: "t", data: { messageId: "m1", threadId: "t1", direction: "inbound", hasAttachments: false } });
    expect((await POST(post(raw, sign(raw)))).status).toBe(204);
    await Promise.all(pending);
    // InboxParse retries a delivery it saw fail; the retry must not fetch again
    expect((await POST(post(raw, sign(raw)))).status).toBe(204);
    await Promise.all(pending);
    expect(await inboxStore.hasEmail("m1")).toBe(true);
    expect(api.calls.filter((c) => c.path === "/emails/m1")).toHaveLength(1);
  });
  it("acknowledges the test event without calling the API", async () => {
    const api = installFakeApi([]);
    const { POST } = await import("@/app/api/inboxparse/webhook/route");
    const raw = JSON.stringify({ event: "test", timestamp: "t", data: { message: "This is a test event from InboxParse", webhook_id: "w" } });
    expect((await POST(post(raw, sign(raw)))).status).toBe(204);
    expect(api.calls).toHaveLength(0);
  });
});
```

```ts
// tests/inboxparse/ingest.test.ts
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ingestEmail, SYNC_MAX_PAGES, SYNC_PAGE_LIMIT, syncEmails } from "@/lib/inboxparse/ingest";
import { createMemoryStore } from "@/lib/inboxparse/store";
import { email, installFakeApi } from "./fake-api";

const now = new Date("2026-10-08T12:00:00.000Z");
const minutesAgo = (n: number) => new Date(now.getTime() - n * 60_000).toISOString();

beforeEach(() => vi.stubEnv("INBOXPARSE_API_KEY", "ip_member"));
afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("ingestEmail", () => {
  it("fetches an unseen email once and calls onNewEmail once", async () => {
    const api = installFakeApi([email("a", minutesAgo(5))]);
    const store = createMemoryStore();
    const onNewEmail = vi.fn(async () => {});
    expect(await ingestEmail(store, "a", { onNewEmail })).toBe("created");
    expect(await ingestEmail(store, "a", { onNewEmail })).toBe("existing");
    expect(api.calls.filter((c) => c.path === "/emails/a")).toHaveLength(1);
    expect(onNewEmail).toHaveBeenCalledTimes(1);
  });
  it("refetches on refresh without calling onNewEmail again", async () => {
    const api = installFakeApi([email("a", minutesAgo(5))]);
    const store = createMemoryStore();
    const onNewEmail = vi.fn(async () => {});
    await ingestEmail(store, "a", { onNewEmail });
    expect(await ingestEmail(store, "a", { onNewEmail, refresh: true })).toBe("updated");
    expect(api.calls.filter((c) => c.path === "/emails/a")).toHaveLength(2);
    expect(onNewEmail).toHaveBeenCalledTimes(1);
  });
  it("reads with the member key, never the admin key", async () => {
    vi.stubEnv("INBOXPARSE_ADMIN_API_KEY", "ip_admin");
    const api = installFakeApi([email("a", minutesAgo(5))]);
    await ingestEmail(createMemoryStore(), "a");
    expect(api.calls.every((c) => c.auth === "Bearer ip_member")).toBe(true);
  });
});

describe("syncEmails", () => {
  it("stores every email in the window across pages and is idempotent on a second run", async () => {
    const emails = Array.from({ length: SYNC_PAGE_LIMIT + 20 }, (_, i) => email(`e${i}`, minutesAgo(i + 1)));
    const api = installFakeApi(emails);
    const store = createMemoryStore();
    const first = await syncEmails(store, { now });
    expect(first).toMatchObject({ created: emails.length, complete: true });
    const detailCalls = api.calls.filter((c) => c.path.startsWith("/emails/")).length;
    const second = await syncEmails(store, { now: new Date(now.getTime() + 60_000) });
    expect(second.created).toBe(0);
    expect(api.calls.filter((c) => c.path.startsWith("/emails/")).length).toBe(detailCalls);
  });
  it("keeps emails that share the sent_at of a page boundary", async () => {
    const tied = minutesAgo(30);
    const emails = [
      ...Array.from({ length: SYNC_PAGE_LIMIT - 1 }, (_, i) => email(`n${i}`, minutesAgo(i + 1))),
      email("tie1", tied),
      email("tie2", tied),
      email("tie3", tied),
    ];
    installFakeApi(emails);
    const store = createMemoryStore();
    await syncEmails(store, { now });
    for (const id of ["tie1", "tie2", "tie3"]) expect(await store.hasEmail(id)).toBe(true);
  });
  it("resumes a walk that hit the page cap instead of restarting at the newest page", async () => {
    const total = SYNC_PAGE_LIMIT * (SYNC_MAX_PAGES + 1) + 5;
    const emails = Array.from({ length: total }, (_, i) => email(`e${i}`, new Date(now.getTime() - (i + 1) * 1000).toISOString()));
    installFakeApi(emails);
    const store = createMemoryStore();
    const first = await syncEmails(store, { now });
    expect(first.complete).toBe(false);
    const second = await syncEmails(store, { now: new Date(now.getTime() + 60_000) });
    expect(second.complete).toBe(true);
    expect(first.created + second.created).toBe(total);
  });
  it("after downtime, starts the window from the last completed walk, not from now", async () => {
    const api = installFakeApi([]);
    const store = createMemoryStore();
    await store.setSyncState({ lastCompletedAt: "2026-10-01T00:00:00.000Z", walk: null });
    await syncEmails(store, { now });
    expect(api.calls[0]?.path).toBe("/emails");
    expect(String(vi.mocked(fetch).mock.calls[0]?.[0])).toContain("date_from=2026-09-29T00%3A00%3A00.000Z");
  });
});
```

```ts
// tests/inboxparse/drafts.test.ts
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { approveDraft } from "@/lib/inboxparse/drafts";
import { createMemoryStore } from "@/lib/inboxparse/store";
import { installFakeApi } from "./fake-api";

const input = { draftId: "form-1", emailId: "a", mailboxId: "mb", body: "  Thanks, see you Monday.  ", approvedBy: "u1" };

beforeEach(() => {
  vi.stubEnv("INBOXPARSE_API_KEY", "ip_member");
  vi.stubEnv("INBOXPARSE_ADMIN_API_KEY", "ip_admin");
});
afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("approveDraft", () => {
  it("sends the approved text once with the admin key, however often the form is submitted", async () => {
    const api = installFakeApi([]);
    const store = createMemoryStore();
    const results = await Promise.all([approveDraft(store, input), approveDraft(store, input)]);
    expect(results.filter((r) => r.ok)).toHaveLength(1);
    expect(await approveDraft(store, input)).toEqual({ ok: false, reason: "already_sent" });
    const replies = api.calls.filter((c) => c.path === "/emails/reply");
    expect(replies).toHaveLength(1);
    expect(replies[0]?.auth).toBe("Bearer ip_admin");
    expect(replies[0]?.body).toEqual({ email_id: "a", mailbox_id: "mb", body: "Thanks, see you Monday." });
  });
  it("refuses an empty body and sends nothing", async () => {
    const api = installFakeApi([]);
    expect(await approveDraft(createMemoryStore(), { ...input, body: "   " })).toEqual({ ok: false, reason: "empty_body" });
    expect(api.calls).toHaveLength(0);
  });
  it("leaves a failed send pending so the same form can be submitted again", async () => {
    const api = installFakeApi([]);
    api.failReply = true;
    const store = createMemoryStore();
    expect(await approveDraft(store, input)).toEqual({ ok: false, reason: "send_failed" });
    api.failReply = false;
    expect((await approveDraft(store, input)).ok).toBe(true);
  });
});
```

Run `npm test`, `npm run typecheck` and `npm run build`; all three pass with no InboxParse variable set. When
the host replaces the memory store, run the same suite against its adapter on a test database: the
concurrent approval test is what proves its `claimDraft` meets the contract.
