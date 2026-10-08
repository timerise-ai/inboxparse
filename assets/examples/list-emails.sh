#!/usr/bin/env bash
# assets/examples/list-emails.sh
# List the newest emails (list items carry no body; use get-email.sh for one).
# Usage: list-emails.sh [limit]   Needs: INBOXPARSE_API_KEY (member key), curl, jq
set -euo pipefail
: "${INBOXPARSE_API_KEY:?Set INBOXPARSE_API_KEY in the environment}"
LIMIT="${1:-10}"
curl -sS --fail-with-body -G "https://inboxparse.com/api/v1/emails" \
  --data-urlencode "limit=${LIMIT}" \
  -H @<(printf 'Authorization: Bearer %s\n' "$INBOXPARSE_API_KEY") | jq .
