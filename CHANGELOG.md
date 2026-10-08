# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This changelog is the skill's audit record. Each release separates what it fixed against the earlier version
of this skill and how the fix was verified, what it kept on purpose and why, and what it added that has not
run outside the test suite.

## [0.1.0] - 2026-10-08

First release under the Timerise Skills standard. The skill now builds an InboxParse integration in a Next.js
App Router app: a typed client, a signed webhook receiver, a scheduled sync and an approved reply flow, with
a 17-test suite. It replaces an earlier version of this skill that documented the V1 API for an agent calling
it directly. Every API fact below was checked against the InboxParse V1 implementation and its reference
documentation on 2026-10-08, and the templates were verified by copying them into the index's eval fixture,
a fresh Next.js 16 App Router app with `strict` and `noUncheckedIndexedAccess`, where `npm run typecheck`,
`npm run build` and `npm test` (17 tests) pass with no InboxParse variable set.

### Fixed

- The webhook signature is documented as it is sent: `X-InboxParse-Signature: sha256=<hex>`, HMAC-SHA256
  over the exact body. The earlier version named `hmac` as an `auth_type`; the values are `none`, `bearer`,
  `basic` and `header`, and they add transport auth on top of the signature.
- Webhook payloads are documented as ids only, with camelCase keys: `email.received` carries `messageId`,
  `threadId`, `direction`, `hasAttachments` and an optional `length`; `email.ai_processed` carries
  `messageId`, `labelId`, `labelName`. The earlier version said they carried the full email.
- Delivery behaviour is stated: one attempt with a 10-second timeout, retries up to 5 attempts, the
  subscription disabled after 10 failures in a row, and `is_active: true` resetting it. The secret is
  generated as `whsec_...` when omitted and returned once.
- `GET /emails` and `POST /search` default to `limit` 50, not 20, and their items carry no `content`; `format`
  applies only to `GET /emails/:id` and `GET /threads/:id`. Email ids are UUIDs, not `msg_` prefixed.
- `reply_to` on `POST /emails/send` is one address, not an array. `POST /labels` requires `color` as six-digit
  hex. `POST /webhooks/:id/test` takes a member key.
- The error table adds `invalid_key`, `missing_query`, `missing_workspace_id`, `smtp_error` (502) and
  `insert_error`, and states that `429` is a monthly quota with no `Retry-After`.
- The example scripts build JSON with `jq --arg` instead of interpolating arguments into a JSON string, which
  broke on a quote in a subject and let an argument add fields; they pass the key to curl from a process
  substitution so it does not appear in the process list.

### Kept

- The untrusted-content rules of the earlier version: email content and `ai.*` fields are never obeyed,
  never interpolated into commands and never sent without explicit user confirmation. They now live in
  `references/untrusted-content.md` and bind both the generated app and an agent using the API directly.
- The member and admin key split, now enforced by the client: reads take `INBOXPARSE_API_KEY`, and only the
  reply path reads `INBOXPARSE_ADMIN_API_KEY`.

### Added

- `references/client.md`: the V1 types, `inboxparseFetch` with `InboxParseError`, `listEmails`, `getEmail`,
  `listMailboxes`, `replyToEmail`.
- `references/webhooks.md`: `verifySignature` and the receiver route, which answers `204` and fetches in
  `after()`.
- `references/sync.md`: `syncEmails` with a 48-hour lookback from the last completed walk, an exact-timestamp
  query at each page boundary because the list cursor pages on `sent_at` alone, and a 10-page cap that saves
  its cursor and resumes. The lookback length and the page cap are design parameters chosen here.
- `references/replies.md`: `approveDraft` with a draft claimed atomically under the id rendered into the form,
  the server action with a session stub that returns `null`, the form and the email page.
- `references/adaptation.md`: the `InboxStore` seam, its contract per method, Postgres DDL and statements, the
  integration points, the rename table and the order of work.
- `references/testing.md`: the Vitest configuration, a fake V1 API and the 17 tests.
- `references/untrusted-content.md` and `references/api-reference.md`, which now covers contacts, compact
  mode, the `format` table and the MCP server.
- `assets/examples/get-email.sh`; `setup-webhook.sh` writes the one-time secret to a file only its owner can
  read instead of printing it.
- `evals/prompts.md` with three operator prompts, and `.github/workflows/agent-eval.yml`, the caller of the
  index's reusable eval workflow.

### Removed

- `references/webhook-events.md`, replaced by `references/webhooks.md`.
- The `metadata` and `license` fields of the `SKILL.md` frontmatter, which now carries `name` and
  `description` only.
