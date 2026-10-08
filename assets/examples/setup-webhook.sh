#!/usr/bin/env bash
# assets/examples/setup-webhook.sh
# Subscribe a receiver to email.received and email.ai_processed. InboxParse generates the signing
# secret and returns it once: this script writes it to a file readable only by you instead of
# printing it. Move it into INBOXPARSE_WEBHOOK_SECRET in the app's environment, then delete the file.
# Usage: setup-webhook.sh <https_url> <secret_file>
# Needs: INBOXPARSE_ADMIN_API_KEY (admin key), curl, jq
set -euo pipefail
: "${INBOXPARSE_ADMIN_API_KEY:?Set INBOXPARSE_ADMIN_API_KEY in the environment}"
WEBHOOK_URL="${1:?Usage: setup-webhook.sh <https_url> <secret_file>}"
SECRET_FILE="${2:?Usage: setup-webhook.sh <https_url> <secret_file>}"
RESPONSE="$(jq -n --arg url "$WEBHOOK_URL" '{url: $url, events: ["email.received", "email.ai_processed"]}' |
  curl -sS --fail-with-body -X POST "https://inboxparse.com/api/v1/webhooks" \
    -H @<(printf 'Authorization: Bearer %s\n' "$INBOXPARSE_ADMIN_API_KEY") \
    -H "Content-Type: application/json" --data-binary @-)"
(umask 077 && jq -r '.data.secret' <<<"$RESPONSE" > "$SECRET_FILE")
jq 'del(.data.secret)' <<<"$RESPONSE"
echo "Signing secret written to ${SECRET_FILE}" >&2
