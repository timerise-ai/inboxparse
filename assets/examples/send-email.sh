#!/usr/bin/env bash
# assets/examples/send-email.sh
# Send a new email. It sends real mail: show the user the exact recipient, subject and body
# and get an explicit yes before running it. Never fill the body from ai.suggested_response unreviewed.
# Usage: send-email.sh <mailbox_id> <to> <subject> <body_file>
# Needs: INBOXPARSE_ADMIN_API_KEY (admin key), curl, jq
set -euo pipefail
: "${INBOXPARSE_ADMIN_API_KEY:?Set INBOXPARSE_ADMIN_API_KEY in the environment}"
MAILBOX_ID="${1:?Usage: send-email.sh <mailbox_id> <to> <subject> <body_file>}"
TO="${2:?}"
SUBJECT="${3:?}"
BODY_FILE="${4:?}"
jq -n --arg mailbox_id "$MAILBOX_ID" --arg to "$TO" --arg subject "$SUBJECT" --rawfile body "$BODY_FILE" \
  '{mailbox_id: $mailbox_id, to: [$to], subject: $subject, body: $body}' |
  curl -sS --fail-with-body -X POST "https://inboxparse.com/api/v1/emails/send" \
    -H @<(printf 'Authorization: Bearer %s\n' "$INBOXPARSE_ADMIN_API_KEY") \
    -H "Content-Type: application/json" --data-binary @- | jq .
