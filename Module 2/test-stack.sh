#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"
[[ -f .env ]] || { echo "ERROR: .env missing. Run ./make-env.sh"; exit 1; }
KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2-)
TEI=${TEI:-http://localhost:8080}; GW=${GW:-http://localhost:4000}
H=(-H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json')

echo "== 1. TEI health / model"
curl -fsS "$TEI/health" >/dev/null && echo "TEI healthy"
curl -fsS "$TEI/info" | jq -r '"model_id: \(.model_id)"'

echo "== 2. TEI OpenAI-style embeddings"
curl -fsS "$TEI/v1/embeddings" -H 'Content-Type: application/json' \
  -d '{"model":"BAAI/bge-base-en-v1.5","input":"hello world"}' \
  | jq -r '"dims: \(.data[0].embedding | length)"'

echo "== 3. LiteLLM -> bge-embed"
curl -fsS "$GW/v1/embeddings" "${H[@]}" -d '{"model":"bge-embed","input":"hi"}' \
  | jq -r '"dims via gateway: \(.data[0].embedding | length)"'

echo "== 4. Routing test requests"
START=$(date -u +%Y-%m-%dT%H:%M:%S)
for p in \
  "What is the capital of Japan?" \
  "My bash script fails with unexpected token, fix it" \
  "Compare three database architectures and recommend one with risks"; do
  code=$(curl -s -o /tmp/test-stack-response.json -w '%{http_code}' --max-time 90 "$GW/v1/chat/completions" "${H[@]}" \
    -d "$(jq -nc --arg p "$p" '{model:"smart_router",max_tokens:1000,messages:[{role:"user",content:$p}]}')")
  echo "HTTP $code - $p"
done

echo "== 5. Routing decisions (duplicates may occur in LiteLLM logs)"
docker compose logs --since "$START" litellm 2>/dev/null | grep 'routing decision' \
  | grep -oE 'cause=[a-z_]+|tier=[A-Z]+|routed_model=[a-z0-9_-]+' \
  | paste - - - | uniq || true

echo "== 6. TEI embedding log matches in this period"
docker compose logs --since "$START" tei 2>/dev/null | grep -ci embed || true
