#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
KEY=$(grep '^OPENROUTER_API_KEY=' .env | cut -d= -f2-)
[[ -n "$KEY" ]] || { echo "OPENROUTER_API_KEY missing in .env"; exit 1; }
FILTER="${1:-.}"
DELAY="${DELAY:-3}"
OUT="free-models-$(date +%Y%m%d-%H%M).tsv"

curl -fsS https://openrouter.ai/api/v1/models -o /tmp/or_models.json || exit 1
mapfile -t MODELS < <(jq -r '.data[] | select(.id | endswith(":free")) | "\(.id)\t\(.context_length)"' /tmp/or_models.json | sort | grep -iE "$FILTER")

printf 'status\tmodel\tcontext\tlatency_s\tnote\n' > "$OUT"
echo "Testing ${#MODELS[@]} free models. Results -> $OUT"
for row in "${MODELS[@]}"; do
  id=${row%%$'\t'*}; ctx=${row#*$'\t'}
  result=$(curl -s -o /tmp/openrouter-scan-response.json -w '%{http_code} %{time_total}' --max-time 60 \
    https://openrouter.ai/api/v1/chat/completions \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$id" '{model:$m,max_tokens:20,messages:[{role:"user",content:"Say hi"}]}')")
  code=${result%% *}; seconds=${result#* }
  note=$(jq -r '.error.message // "ok"' /tmp/openrouter-scan-response.json 2>/dev/null | tr '\t\n' '  ' | cut -c1-90)
  [[ "$code" == "000" ]] && note="timeout / no response"
  printf '%s\t%s\t%s\t%.1f\t%s\n' "$code" "$id" "$ctx" "$seconds" "$note" | tee -a "$OUT"
  sleep "$DELAY"
done

echo
echo "== Working models (HTTP 200) =="
awk -F'\t' '$1==200 {printf "%-60s ctx=%-9s %ss\n", $2, $3, $4}' "$OUT"
