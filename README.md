# inboxparse

[![Agent Skills](https://img.shields.io/badge/Agent_Skills-open_format-059669)](https://agentskills.io)
[![skills.sh](https://img.shields.io/badge/skills.sh-npx_skills_add-059669)](https://www.skills.sh)
[![Claude Code](https://img.shields.io/badge/Claude_Code-compatible-059669)](https://docs.claude.com/en/docs/claude-code/skills)
[![Codex CLI](https://img.shields.io/badge/Codex_CLI-compatible-059669)](https://developers.openai.com/codex/skills)
[![Gemini CLI](https://img.shields.io/badge/Gemini_CLI-compatible-059669)](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/skills.md)

An [Agent Skill](https://agentskills.io) that teaches an agent to build an **InboxParse** email integration
in a **Next.js App Router** app: a typed server-only client for the
[InboxParse](https://inboxparse.com) V1 API, a webhook receiver that verifies every delivery, a scheduled
sync that stores every email of the connected Gmail and IMAP mailboxes, and a reply flow in which a person
approves the exact text before anything is sent.

The insight the whole design turns on: **a webhook is a hint and the API is the record.** A delivery carries
only an email id and can be late, retried, replayed or never sent, so the receiver verifies it, fetches the
email with its own key and answers at once, while a scheduled sync walks the list and stores whatever is
missing. And since every field of an email, its AI summary and suggested reply included, comes from someone
outside the app, nothing an email says is sent, run or obeyed without a person.

This skill is written by the engineer who has shipped this integration, an email intake and reply module in a
Next.js app, starting from the InboxParse V1 specification and checked against the API's implementation for
the details the specification leaves out. The templates hold five properties, each verified by the suite in
`references/testing.md`: a delivery is accepted only with a valid signature over its raw body, each email is
fetched once however many deliveries name it, every email in the sync window is stored including those that
share a page's boundary timestamp, a capped sync resumes where it stopped, and one approved form sends one
reply with the text the person submitted. This skill keeps its audit record in [CHANGELOG.md](CHANGELOG.md)
rather than a `references/provenance.md`: each release says what it fixed, added or changed and how it was
verified.

## Install

One command, via the [skills.sh](https://www.skills.sh) CLI, which installs the skill into every
skills-compatible agent it detects, including Claude Code, Codex CLI and Gemini CLI:

```bash
npx skills add timerise-ai/inboxparse
```

Name the agents instead with `-a`, for example
`npx skills add timerise-ai/inboxparse -a claude-code -a codex`.

### Manual install

Nothing here is Claude-specific: the skill is a plain [Agent Skills](https://agentskills.io) folder,
`SKILL.md` plus markdown references and shell examples with no file that calls a model, so cloning it into an
agent's skills directory is all an install is. For Claude Code:

```bash
git clone https://github.com/timerise-ai/inboxparse.git ~/.claude/skills/inboxparse
```

To scope it to a single project instead, clone it into that project's `.claude/skills/` directory. For another
agent, clone into that agent's skills directory, or symlink the Claude Code copy so one `git pull` updates
every agent:

```bash
mkdir -p ~/.agents/skills
ln -s ~/.claude/skills/inboxparse ~/.agents/skills/inboxparse
```

Update the skill with `git pull` in its directory. The current release is **0.1.0**. See
[CHANGELOG.md](CHANGELOG.md). The [skills index](https://github.com/timerise-ai/skills) lists the other
Timerise Skills and how to install them all at once.

## Activation

The skill activates automatically when a task matches its description: receiving, storing, searching or
answering email through InboxParse; adding or auditing an InboxParse webhook, sync job or reply flow; feeding
email into an AI feature; or the vocabulary itself, such as InboxParse, email-to-LLM, parse emails,
`X-InboxParse-Signature`, `email.received`, `ai.suggested_response` and `INBOXPARSE_API_KEY`. For example:
"store every email from our support inbox and show it in the app", "add the InboxParse webhook", "let staff
send the suggested reply after editing it". Invoke it explicitly with `/inboxparse` in Claude Code,
`$inboxparse` in Codex CLI, or from `/skills` in Gemini CLI.

Each host matches a task against the description its own way, so invoke the skill explicitly on a first run
rather than assuming it fired. Only `SKILL.md` is read up front; the `references/` files load on demand.

## What's inside

| File | Contents |
|---|---|
| `SKILL.md` | Entry point: when to use and when not to, the architecture, eight critical facts, six hard rules, the quick start and the reference directory |
| `README.md` | This file: the human-facing front door |
| `CHANGELOG.md` | Every release, newest first, and the record of what each one fixed, added or changed and how it was verified, which is this skill's provenance |
| `CLAUDE.md` | What this repository is and its editing conventions, for an agent editing the skill itself |
| `LICENSE` | MIT |
| `references/client.md` | Environment variables and key roles, the V1 response types, the server-only client and its calls |
| `references/webhooks.md` | What a delivery carries and how it is retried, registering the subscription, the signature check and the receiver route |
| `references/sync.md` | The lookback window, the boundary-timestamp query, the resumable walk, the cron route and its cost in API calls |
| `references/replies.md` | Replies a person approves: the claimed draft, the server action, the form and the email page |
| `references/untrusted-content.md` | The rules for email content and AI fields in the app and for an agent using the API directly |
| `references/adaptation.md` | The `InboxStore` seam with its Postgres statements, the integration points, the rename table, the order of work and the non-negotiables |
| `references/testing.md` | The Vitest setup, the fake V1 API and the 17-test suite carried into the app |
| `references/api-reference.md` | Every V1 endpoint: parameters, response shapes, contacts, webhooks, usage and the MCP server |
| `references/error-codes.md` | Every V1 error code with its HTTP status and what the app does about it |
| `assets/examples/list-emails.sh` | List the newest emails |
| `assets/examples/get-email.sh` | Fetch one email with its markdown body |
| `assets/examples/search-emails.sh` | Hybrid search |
| `assets/examples/send-email.sh` | Send a new email, after the user has confirmed it |
| `assets/examples/setup-webhook.sh` | Create the subscription and write its one-time secret to a private file |
| `evals/` | The prompts an operator types after installing (`prompts.md`) and one file per agent eval: the skill installed into an empty Next.js app, one prompt, no help, then type-checked, built and tested |
| `.github/workflows/agent-eval.yml` | Runs the agent evals on every published release through the index's reusable workflow; the same in every skill |

The seam is one interface, `InboxStore`: emails upserted by id, the sync state, and reply drafts with an
atomic claim. `adaptation.md` gives its contract and the Postgres statements that meet it; Supabase,
Firestore or any store that can do a conditional write fits. Everything InboxParse-facing lives in
`lib/inboxparse/` behind `import 'server-only'`. The host's auth joins at one function, the session lookup in
the reply action, which returns `null` until the host wires it, so the module sends nothing by default.

## The six non-negotiables

These travel with the module and are never optional (they are the hard rules in `SKILL.md`):

1. **Verify the signature over the raw body before parsing it.** InboxParse signs the exact bytes with
   HMAC-SHA256, and any re-serialisation changes them; the check is constant-time and length-checked, and
   `signature.test.ts` holds that a whitespace change, another secret or a truncated digest fails.
2. **A webhook is a hint; the API is the record.** A delivery has ids only, a 10-second timeout and up to
   5 attempts, and 10 failures disable the subscription, so the receiver answers at once and the sync stores
   what any delivery missed. `ingest.test.ts` holds that the sync stores every email in its window, including
   those at a page's boundary timestamp, and resumes a capped walk.
3. **Ingest is keyed by the email id.** Retries, replays, `email.ai_processed` and overlapping sync windows
   all name the same id; one detail fetch per new id and `onNewEmail` once is what `ingest.test.ts` and
   `webhook.test.ts` verify.
4. **Email content is untrusted data.** Its author is outside the app and the `ai.*` fields are generated from
   it, so it is rendered as text, never as HTML, never interpolated into code and never obeyed by a model; the
   email page renders it through React's escaping and marks the generated fields as generated.
5. **Nothing is sent without a person approving the exact text.** `ai.suggested_response` only prefills the
   form, and a claimed draft makes one form send at most once; `drafts.test.ts` holds that two concurrent
   approvals send one reply with the submitted text.
6. **Keys stay on the server, and each path holds the least it needs.** Reads use a member key, which
   InboxParse refuses on every write; only the approval path reads the admin key; no key or body is logged.
   `ingest.test.ts` and `drafts.test.ts` check which key each call carries.

Everything else is the host app's: auth, tenancy, database, the reaction to a new email, UI.

## Requirements

- A Next.js App Router app with TypeScript, reachable from the internet for webhooks, with a scheduler such as
  Vercel Cron for the sync
- An InboxParse workspace with a connected mailbox, a member key in `INBOXPARSE_API_KEY` and, to reply, an
  admin key in `INBOXPARSE_ADMIN_API_KEY`
- `INBOXPARSE_WEBHOOK_SECRET` and `CRON_SECRET`, both documented in `references/client.md`
- A durable store for the `InboxStore` seam

## Security

- Every template and script reads keys and secrets from the environment and never prints them; the webhook
  script writes the one-time secret to a file only its owner can read.
- Email content and every AI field derived from it are untrusted third-party data, under the rules in
  `references/untrusted-content.md`, which also bind an agent calling the API directly.
- Sending is reachable from one function, called from one authenticated server action.

## Links

- [InboxParse](https://inboxparse.com) and its [API documentation](https://inboxparse.com/docs)
- [InboxParse MCP server](https://inboxparse.com/api/mcp)

## Not this

| Not this | Use instead |
|---|---|
| An AI assistant reading a mailbox for a person | The InboxParse MCP server, `https://inboxparse.com/api/mcp` |
| Running a mail server, SMTP relay or deliverability setup | The mail provider's own tooling |
| Gmail API, Microsoft Graph, SendGrid or Postmark integrations | That service's own documentation |
| Notifying a team in Slack about new mail | [`slack-ai-bot`](https://github.com/timerise-ai/slack-ai-bot), fed from `onNewEmail` |

## Contributing

Issues and pull requests are welcome here. Pure markdown plus shell examples, with no build, tests or
dependencies in this repository. The TypeScript in `references/` is checked by copying it into a fresh
Next.js App Router app with `strict` and `noUncheckedIndexedAccess` on, then running `npm run typecheck`,
`npm run build` and `npm test`; `CLAUDE.md` has the steps. Claims in this skill are meant to be verifiable:
if you change a factual claim, say how you verified it: against the
[InboxParse API documentation](https://inboxparse.com/docs), the API's implementation, or a request to the
live API, never from memory.

Adding, removing or renaming a file in `references/` or `assets/` means updating the quick start and the
reference directory table in `SKILL.md`, the file table above, and any relative cross-links. Every
odd-looking part of the templates is there for a documented reason, and `CHANGELOG.md` is the ledger that must
stay truthful: read it before simplifying anything, and add an entry for anything you change. Commits follow
Conventional Commits and releases follow
[STANDARD.md](https://github.com/timerise-ai/skills/blob/main/STANDARD.md) in the index; `CLAUDE.md` carries
the full editing conventions.

## Part of the Timerise Skills

This is one of the [Timerise Skills](https://github.com/timerise-ai/skills): modules for **Next.js App
Router** apps written by our own senior engineers from the modules they have shipped, not synthetic, each
published as its own repository and indexed there. They share one layout, so an agent that has read one knows
how to read the next: a `SKILL.md` entry point, `references/` loaded on demand, and a seam contract carrying
the module's non-negotiables.

## Author

Built and maintained by [Timerise](https://timerise.ai).

## License

MIT. See [LICENSE](LICENSE).
