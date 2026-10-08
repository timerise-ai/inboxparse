# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repository is

An [Agent Skill](https://agentskills.io) package: markdown plus shell examples, with no build, no tests and
no dependencies. Nothing in this repository executes as an application. It teaches an agent to build an
InboxParse email integration in a **Next.js App Router** app: a typed client for the V1 API, a signed webhook
receiver, a scheduled sync and a reply flow a person approves. Published as
[`timerise-ai/inboxparse`](https://github.com/timerise-ai/inboxparse).

Keep the two straight: the code, SQL and `vercel.json` in `references/` describe the app the agent will
generate, not this repository. The scripts in `assets/examples/` are the exception: they run standalone in a
shell with `curl` and `jq`.

The skill was written by the engineer who has shipped this integration, starting from the InboxParse V1
specification and checked against the API's implementation. It is an integration skill written from a vendor
specification, so it keeps its audit record in `CHANGELOG.md` instead of `references/provenance.md`: each
release records what it fixed, kept or added, why, and how it was verified. That file is the rationale layer:
read it before simplifying anything.

## Structure

- `SKILL.md`: entry point, loaded whole on every activation, so it stays between 130 and 160 lines, the
  closing index line aside. The frontmatter `description` is the trigger surface; the body carries the
  architecture, eight **critical facts**, six **hard rules**, the quick start, the **reference directory
  table** and a closing line linking the skills index.
- `README.md`: the human-facing front door, in the section order of the skill standard, with the current
  release line under *Manual install*.
- `references/*.md`: one concern per file. `client.md` is the base every other file builds on;
  `adaptation.md` is the seam contract (`InboxStore`) and restates the non-negotiables; `testing.md` carries
  the suite; `untrusted-content.md` holds the rules the others follow; `api-reference.md` and
  `error-codes.md` cover the whole V1 API.
- `assets/examples/*.sh`: standalone scripts for an agent or person calling the API from a shell. Keys come
  from the environment only.
- `evals/`: `prompts.md` holds what an operator types after installing, in their words; the first prompt is
  the agent eval run before every release. Every other file there is one eval run: measured frontmatter that
  is never edited, then the notes of the person who ran it. Add a prompt rather than rewording one that has
  results. The procedure is section 10 of the index's STANDARD.md.
- `.github/workflows/agent-eval.yml`: the caller of the index's reusable eval workflow, run on every
  published release and on a maintainer's dispatch. It is copied verbatim from the standard and is the same
  in every skill; do not edit it, and never add a trigger on `push` or `pull_request`.

## Editing conventions

- **Code blocks name their destination on the first line** as a comment, for example
  `// lib/inboxparse/client.ts` or `-- db/inboxparse.sql`. A block that continues a file already introduced
  omits it, as do JSON bodies and shell commands.
- **Identifiers are shared across files.** `inboxparseFetch`, `InboxParseError`, `listEmails`, `getEmail`,
  `listMailboxes`, `replyToEmail`, `verifySignature`, `SIGNATURE_HEADER`, `ingestEmail`, `syncEmails`,
  `approveDraft`, `InboxStore`, `createMemoryStore`, `inboxStore`, `SyncState`, `ReplyDraft`, `onNewEmail`,
  the `inboxparse_*` tables and the env names `INBOXPARSE_API_KEY`, `INBOXPARSE_ADMIN_API_KEY`,
  `INBOXPARSE_WEBHOOK_SECRET`, `INBOXPARSE_BASE_URL` and `CRON_SECRET` appear in several references. Rename
  in all of them or none.
- **Keep the three tables in sync** with `references/` and `assets/`: the reference directory in `SKILL.md`,
  the quick start in `SKILL.md`, and the file table in `README.md`. Links are relative:
  `[x.md](references/x.md)` from `SKILL.md`, `[x.md](x.md)` between references.
- **Verify the templates** before a release that touches code. Copy `eval/fixture/` from the index to a
  scratch folder, rename `gitignore` to `.gitignore`, add `"noUncheckedIndexedAccess": true` to its
  `tsconfig.json`, run `npm install`, `npm i server-only` and `npm i -D vitest`, write every block of
  `references/` that names a destination to that path, set `"test": "vitest run"`, then run
  `npm run typecheck`, `npm run build` and `npm test` with no InboxParse variable set. All three pass on the
  current release, with 17 tests.
- **Do not remove the odd-looking parts.** The exact-timestamp query at a page boundary, the resumable walk,
  the lookback measured from the last completed walk instead of now, `request.text()` before any parse, the
  length check before `timingSafeEqual`, the `204` to events the module ignores, `refresh` on
  `email.ai_processed`, the `draftId` rendered into the form, and the session stub that returns `null`: each
  holds for a reason recorded in `CHANGELOG.md`.
- **The numbers that remain are load-bearing.** API facts (the 10-second delivery timeout, 5 attempts,
  10 failures to disable, `limit` 1 to 100 with a default of 50) and design parameters (the 48-hour
  lookback, the 10-page cap). Do not add a number without saying where it was verified.
- **Source of truth.** The InboxParse API documentation at https://inboxparse.com/docs and the API's
  implementation. Any change to an endpoint, a field, a header, an event or a limit is verified there first,
  never from memory, and the changelog entry says how.
- **Mark additions as additions.** Anything the skill designs beyond the API, such as the sync window, the
  draft claim and the store contract, is recorded under *Added* in the changelog entry that introduces it.
- **Never present the non-negotiables as optional.** The signature over the raw body, the webhook as a hint,
  ingest keyed by id, untrusted content, sending only after a person approves the text, and least-privilege
  keys on the server. They are the hard rules in `SKILL.md`, the non-negotiables in `README.md` and the list
  in `adaptation.md`, in the same order; keep them that way everywhere.
- **What the host renames and what it does not.** Folder names, route paths, table names, `inboxStore` and
  the word draft are the host's. InboxParse's field names, event names, header names and the env var names
  are the authoring contract.
- **No secrets anywhere.** Templates and scripts read keys from the environment and never print them. Keep
  `.claude/settings.local.json` out of git: it is ignored because it can hold local tokens.
- **Plain punctuation.** No em-dash, en-dash, arrow, middle dot or smart quote anywhere, diagrams included:
  draw them in ASCII. Prose wraps at 110 columns.
- **The version lives in three places that agree**: the newest `CHANGELOG.md` section, the current-release
  line in `README.md`, and the `vX.Y.Z` git tag. The release commit is `chore(release): X.Y.Z` and contains
  only those two files. `SKILL.md` frontmatter carries only `name` and `description`.
- **Evals are not skill content.** A new prompt or an eval result is committed as `chore(evals): ...`, never
  causes a version bump and never rides in a release commit. A failing run stays committed; the fix is the
  next release.
- **No attribution to tools.** No generated-by lines and no assistant trailers, in files or commits.
