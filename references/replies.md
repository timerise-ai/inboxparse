# Replies

Sending a reply that a person has read and approved, and nothing else. It assumes the client of
[client.md](client.md), the store seam of [adaptation.md](adaptation.md) and the rules of
[untrusted-content.md](untrusted-content.md).

## The rule

**`POST /emails/reply` and `POST /emails/send` run only from an action a signed-in person submitted, with the
text that person submitted.** `ai.suggested_response` is generated from the incoming email, whose author is
outside the app; it prefills the reply box and is never sent by code. No ingest path, webhook, cron, model
tool or `onNewEmail` hook imports `replyToEmail`.

The flow:

1. The email page renders the email as text, the generated fields marked as generated, and a form whose
   textarea is prefilled with `ai.suggested_response`. The page also renders a fresh `draftId`.
2. The person edits the text, picks the mailbox to send from (`GET /mailboxes`; the email itself does not
   name one) and submits.
3. The server action checks the session, then `approveDraft` saves the draft under `draftId` if it is new,
   claims it from `pending` to `sending`, and sends exactly the submitted body with the admin key.
4. Success marks the draft `sent`; a failure returns it to `pending` so the same form can be submitted again.

**One rendered form sends at most once.** The claim is atomic in the store, so a double click, a retried
request or two tabs on the same form send one reply. A new page load renders a new `draftId`, which is a new
decision by the person.

## Approval

```ts
// lib/inboxparse/drafts.ts
import "server-only";
import { replyToEmail } from "./client";
import type { InboxStore } from "./store";

export interface ApproveInput {
  draftId: string;
  emailId: string;
  mailboxId: string;
  // the text the approving person submitted, exactly as they saw it
  body: string;
  approvedBy: string;
}

export type ApproveResult =
  | { ok: true; sentMessageId: string }
  | { ok: false; reason: "unauthorized" | "empty_body" | "already_sent" | "send_failed" };

// The only caller of replyToEmail. A draft id is claimed once, so a double submit
// or a retried request sends nothing the second time.
export async function approveDraft(store: InboxStore, input: ApproveInput): Promise<ApproveResult> {
  const body = input.body.trim();
  if (!body) return { ok: false, reason: "empty_body" };
  await store.saveDraft({
    id: input.draftId,
    emailId: input.emailId,
    mailboxId: input.mailboxId,
    body,
    approvedBy: input.approvedBy,
  });
  const draft = await store.claimDraft(input.draftId);
  if (!draft) return { ok: false, reason: "already_sent" };
  try {
    const sent = await replyToEmail({ emailId: draft.emailId, mailboxId: draft.mailboxId, body: draft.body });
    await store.finishDraft(draft.id, { status: "sent", sentMessageId: sent.id });
    return { ok: true, sentMessageId: sent.id };
  } catch (error) {
    await store.finishDraft(draft.id, { status: "pending" });
    console.error("[inboxparse] reply failed", { draftId: draft.id, error: String(error) });
    return { ok: false, reason: "send_failed" };
  }
}
```

## Server action

```ts
// app/inbox/actions.ts
"use server";
import { approveDraft, type ApproveResult } from "@/lib/inboxparse/drafts";
import { inboxStore } from "@/lib/inboxparse/instance";

// Replace with the host's session lookup; it returns null for anyone not allowed to send.
async function currentUserId(): Promise<string | null> {
  return null;
}

export async function approveReply(_previous: ApproveResult | null, formData: FormData): Promise<ApproveResult> {
  const approvedBy = await currentUserId();
  if (!approvedBy) return { ok: false, reason: "unauthorized" };
  return approveDraft(inboxStore, {
    draftId: String(formData.get("draftId") ?? ""),
    emailId: String(formData.get("emailId") ?? ""),
    mailboxId: String(formData.get("mailboxId") ?? ""),
    body: String(formData.get("body") ?? ""),
    approvedBy,
  });
}
```

`currentUserId` is the host's session lookup; it returns `null` for anyone not allowed to send, and the stub
returns `null` until the host wires it, so nothing sends by default. Record `approvedBy` with the reply: it is
who decided the text.

## Form and page

```tsx
// app/inbox/reply-form.tsx
"use client";
import { useActionState } from "react";
import { approveReply } from "./actions";

interface ReplyFormProps {
  draftId: string;
  emailId: string;
  mailboxes: Array<{ id: string; email: string }>;
  suggestion: string;
}

export function ReplyForm({ draftId, emailId, mailboxes, suggestion }: ReplyFormProps) {
  const [result, action, pending] = useActionState(approveReply, null);
  if (result?.ok) return <p role="status">Reply sent.</p>;
  return (
    <form action={action}>
      <input type="hidden" name="draftId" value={draftId} />
      <input type="hidden" name="emailId" value={emailId} />
      <label>
        Send from
        <select name="mailboxId" required>
          {mailboxes.map((mailbox) => (
            <option key={mailbox.id} value={mailbox.id}>
              {mailbox.email}
            </option>
          ))}
        </select>
      </label>
      <label>
        Reply (generated draft: read and edit before sending)
        <textarea name="body" defaultValue={suggestion} rows={10} required />
      </label>
      <button type="submit" disabled={pending}>
        Send this reply
      </button>
      {result && !result.ok ? <p role="alert">Not sent: {result.reason}</p> : null}
    </form>
  );
}
```

```tsx
// app/inbox/[id]/page.tsx
import { randomUUID } from "node:crypto";
import { notFound } from "next/navigation";
import { listMailboxes } from "@/lib/inboxparse/client";
import { inboxStore } from "@/lib/inboxparse/instance";
import { ReplyForm } from "../reply-form";

export const dynamic = "force-dynamic";

export default async function EmailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const email = await inboxStore.findEmail(id);
  if (!email) notFound();
  const mailboxes = await listMailboxes();

  // Email content and every ai.* field are untrusted text: rendered as text, never as HTML.
  return (
    <main>
      <h1>{email.subject ?? "(no subject)"}</h1>
      <p>
        From {email.from.name ?? ""} &lt;{email.from.email}&gt;, {email.sent_at}
      </p>
      <pre style={{ whiteSpace: "pre-wrap" }}>{email.content.markdown ?? ""}</pre>
      <section aria-label="Generated from this email, unverified">
        <p>Summary: {email.ai.summary ?? "none"}</p>
        <p>Labels: {email.ai.labels.map((label) => label.name).join(", ") || "none"}</p>
      </section>
      <ReplyForm
        draftId={randomUUID()}
        emailId={email.id}
        mailboxes={mailboxes.map(({ id: mailboxId, email: address }) => ({ id: mailboxId, email: address }))}
        suggestion={email.ai.suggested_response ?? ""}
      />
    </main>
  );
}
```

Recipients default to the original sender, threading headers and the `Re:` subject are set by InboxParse, and
the response is `201` with `{ id, thread_id, status: "sent", smtp_message_id }`. An SMTP failure is
`502 smtp_error`; an SMTP sending limit is `429 rate_limit_exceeded`.

## New emails

`POST /emails/send` (`mailbox_id`, `to`, `subject`, `body`, optional `cc`, `bcc`, `html_body`, `reply_to`)
starts a new thread. It follows the same rule and the same claim: add a `sendEmail` beside `replyToEmail` with
`role: "send"`, called from its own approval function, never from code that read an email.
