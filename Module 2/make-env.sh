#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .env ]]; then
  echo "ERROR: .env already exists. Refusing to overwrite secrets."
  exit 1
fi

read -rsp "OpenRouter API key: " OPENROUTER_API_KEY
echo
[[ -n "$OPENROUTER_API_KEY" ]] || { echo "ERROR: empty API key"; exit 1; }

MASTER="sk-$(openssl rand -hex 16)"
SALT="sk-$(openssl rand -hex 16)"
PG="$(openssl rand -hex 12)"

cat > .env <<EOF2
OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
LITELLM_MASTER_KEY=${MASTER}
LITELLM_SALT_KEY=${SALT}
POSTGRES_PASSWORD=${PG}
DATABASE_URL=postgresql://litellm:${PG}@db:5432/litellm
EOF2
chmod 600 .env
unset OPENROUTER_API_KEY PG SALT

echo "Created .env with mode 600."
echo "LiteLLM master key (save this securely): ${MASTER}"
unset MASTER
