#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
FILE="${1:-tests/prompts.txt}"
KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2-)
PASS=0; TOTAL=0
[[ -n "$KEY" ]] || { echo "ERROR: LITELLM_MASTER_KEY not found in .env"; exit 1; }
[[ -f "$FILE" ]] || { echo "ERROR: Prompt file not found: $FILE"; exit 1; }

printf '%-6s %-10s %-10s %-24s %-16s %s\n' RESULT EXPECTED GOT CAUSE ROUTED_MODEL PROMPT
while IFS='|' read -r expected prompt; do
  [[ -z "${expected:-}" || "$expected" == \#* ]] && continue
  start_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  payload=$(jq -nc --arg p "$prompt" '{model:"smart_router",max_tokens:1,messages:[{role:"user",content:$p}]}')
  http_code=$(curl -s -o /tmp/route-eval-response.json -w '%{http_code}' --max-time 60 \
    http://localhost:4000/v1/chat/completions \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$payload")
  sleep 1
  line=$(docker compose logs --since "$start_time" litellm 2>/dev/null | grep 'routing decision' | tail -1)
  got=$(grep -oE 'tier=[A-Z]+' <<< "$line" | head -1 | cut -d= -f2)
  cause=$(grep -oE 'cause=[a-z_]+' <<< "$line" | head -1 | cut -d= -f2)
  routed=$(grep -oE 'routed_model=[a-z0-9_-]+' <<< "$line" | head -1 | cut -d= -f2)
  TOTAL=$((TOTAL + 1)); RESULT=MISS
  [[ "$got" == "$expected" ]] && { RESULT=OK; PASS=$((PASS + 1)); }
  printf '%-6s %-10s %-10s %-24s %-16s %s [HTTP %s]\n' \
    "$RESULT" "$expected" "${got:-?}" "${cause:-?}" "${routed:-?}" "$prompt" "$http_code"
  sleep 2
done < "$FILE"
echo
echo "Result: $PASS/$TOTAL prompts routed to expected tier"
[[ "$TOTAL" -gt 0 ]] && awk -v p="$PASS" -v t="$TOTAL" 'BEGIN {printf "Routing accuracy: %.1f%%\n", (p/t)*100}'
