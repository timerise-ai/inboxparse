# Error codes

Every V1 error is `{ "error": { "message": "...", "code": "..." } }`; `InboxParseError` in
[client.md](client.md) carries `status` and `code`. Branch on `code`, never on `message`.

| Code | HTTP | Meaning | What the app does |
|---|---|---|---|
| `unauthorized` | 401 | Missing, malformed or revoked key | Check the variable is set and starts with `ip_`; do not retry |
| `invalid_key` | 401 | The key has no workspace | Create a new key in the console |
| `forbidden` | 403 | A member key on an admin endpoint, or a write to a system label | Send only from the path that holds `INBOXPARSE_ADMIN_API_KEY` |
| `not_found` | 404 | No such resource in this key's workspace | For a webhook `messageId`, check the key belongs to the subscription's workspace |
| `validation_error` | 400 | A field is missing, mistyped or out of range | Fix the request; do not retry |
| `missing_query` | 400 | `POST /search` without `query` | Fix the request |
| `invalid_cursor` | 400 | A cursor that was not returned by the API | Pass `next_cursor` exactly as received |
| `missing_workspace_id` | 400 | A dashboard session call without `workspace_id` | Not reachable with an API key |
| `duplicate` | 409 | The label name exists | Use the existing label or another name |
| `rate_limit_exceeded` | 429 | The plan's monthly API calls, mailboxes or SMTP sending is used up | Stop and report; there is no `Retry-After`, and `GET /usage` shows the period |
| `smtp_error` | 502 | The mail server refused or failed the send | The draft returns to `pending`; the person may submit again |
| `query_error`, `insert_error` | 500 | A database error inside InboxParse | Retry later; the sync's next run does so by itself |
| `internal_error` | 500 | An unexpected server error | Retry later |
