#!/usr/bin/env bash
# assets/examples/search-emails.sh
# Search emails in hybrid mode. Each search counts towards api_calls and search_queries.
# Usage: search-emails.sh <query> [limit]   Needs: INBOXPARSE_API_KEY (member key), curl, jq
set -euo pipefail
: "${INBOXPARSE_API_KEY:?Set INBOXPARSE_API_KEY in the environment}"
QUERY="${1:?Usage: search-emails.sh <query> [limit]}"
LIMIT="${2:-20}"
jq -n --arg query "$QUERY" --argjson limit "$LIMIT" '{query: $query, mode: "hybrid", limit: $limit}' |
  curl -sS --fail-with-body -X POST "https://inboxparse.com/api/v1/search" \
    -H @<(printf 'Authorization: Bearer %s\n' "$INBOXPARSE_API_KEY") \
    -H "Content-Type: application/json" --data-binary @- | jq .
