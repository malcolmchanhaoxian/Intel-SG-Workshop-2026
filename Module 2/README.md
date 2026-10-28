# Xeon Semantic/Complexity Routing Lab

A clean lab bundle validated during a test deployment:

- `BAAI/bge-base-en-v1.5` served by Hugging Face TEI on Intel Xeon CPU
- LiteLLM AI Gateway / Proxy
- LiteLLM `auto_router/complexity_router`
- BGE semantic keyword matching plus LiteLLM heuristic fallback
- OpenRouter model backends
- Single client-facing model name: `smart_router`


## Files

- `docker-compose.yml` - TEI, PostgreSQL and LiteLLM
- `config.yaml` - BGE, OpenRouter models and smart router
- `.env.example` - environment variable template
- `make-env.sh` - safely creates `.env` and matching PostgreSQL credentials
- `test-stack.sh` - layer-by-layer health and routing test
- `scan-free-models.sh` - tests current OpenRouter `:free` models
- `route-eval.sh` - routing-quality evaluator
- `tests/prompts.txt` - 15 labelled learner prompts; uses `TIER|prompt` format

## 0. Prerequisites (Ubuntu 24.04)

Install Docker Engine / Compose using Docker's official Ubuntu repository. Also install `jq`, `curl`, and `openssl`.

After Docker is installed, add your user to the `docker` group and reconnect the SSH session (or use `newgrp docker`). Verify:

```bash
docker --version
docker compose version
docker run --rm hello-world
```

## 1. Configure secrets

```bash
cd ~/xeon-smart-router
./make-env.sh
```

The script asks only for the OpenRouter key, then generates the LiteLLM master key, salt key and PostgreSQL password. It writes `.env` with mode `600` and ensures the password in `DATABASE_URL` matches `POSTGRES_PASSWORD`.

Never change `LITELLM_SALT_KEY` after the database begins storing encrypted secrets.

## 2. Start the stack

```bash
docker compose up -d
docker compose ps
docker compose logs -f litellm
```

Press Ctrl+C after LiteLLM is listening. This stops only the log view.

Services:
- TEI: host port 8080
- LiteLLM: host port 4000
- PostgreSQL: internal Docker network only

TEI is pinned to Xeon cores `0-7` in `docker-compose.yml`. Adjust `cpuset` to match the intended CPU allocation.

## 3. Test each layer

```bash
./test-stack.sh
```

Expected core signals:
- TEI healthy
- model ID `BAAI/bge-base-en-v1.5`
- local embedding dimension 768
- embedding dimension 768 when called through LiteLLM
- routing decisions showing `tier=...` and `routed_model=...`

`cause=semantic_keyword_match` means BGE semantic phrase matching selected the tier.
`cause=heuristic_scorer` means LiteLLM's built-in complexity scorer selected the tier.

LiteLLM can log the same routing decision twice; duplicates do not represent extra user requests.

## 4. OpenAI-compatible application endpoint

Applications use:

- Base URL: `http://<gateway-host>:4000/v1`
- Chat endpoint: `/chat/completions`
- Model: `smart_router`

Example from the gateway host:

```bash
export KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2-)
curl -s localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"smart_router","max_tokens":1000,"messages":[{"role":"user","content":"Write a python function to reverse a string"}]}' \
  | jq -r '.choices[0].message.content // .error.message'
```

Reasoning-capable backends can consume much of the completion budget in reasoning tokens. A 100-token test produced `finish_reason=length` before returning answer content during validation, while a 1000-token request returned the answer. For learning tests use `max_tokens: 1000` or inspect the model's reasoning/token behavior explicitly.

## 5. LiteLLM UI

Do not expose port 4000 publicly merely to access the admin UI.

A reliable method is a local gcloud tunnel from a workstation:

```bash
gcloud config set project <PROJECT_ID>
gcloud compute ssh <VM_NAME> --zone <ZONE> -- -N -L 4000:localhost:4000
```

Then open `http://localhost:4000/ui` locally. A Cloud Shell Web Preview can render the UI but, in the tested environment, Models and Logs were empty through the preview even though server-side APIs contained the data.

If Cloud Shell is used for an SSH tunnel and IPv6 binding fails, bind IPv4 explicitly:

```bash
gcloud compute ssh <VM_NAME> --zone <ZONE> -- -4 -N -L 127.0.0.1:8080:localhost:4000
```

## 6. Create application keys

In the LiteLLM UI create a Virtual Key with:

- Models: `smart_router` only
- Key type: LLM API
- Alias: e.g. `test-app`

This prevents an application from directly bypassing routing through `default-llm`, `coder-llm`, `reasoning-llm`, or `bge-embed`.

## 7. Evaluate routing quality

```bash
./route-eval.sh
```

The evaluator intentionally uses `TIER|prompt` rather than tabs so browser SSH copy/paste cannot silently corrupt the input format.

The included prompt set was deliberately left at the validated 80% expected-tier accuracy for teaching. Learners can inspect whether each decision was made by `semantic_keyword_match` or `heuristic_scorer`, then experiment with utterances or `match_threshold` themselves.

## 8. Scan currently available OpenRouter free models

Free model availability and provider health can change. Test the current free inventory instead of assuming a free model is callable:

```bash
./scan-free-models.sh
```

Filter it if desired:

```bash
./scan-free-models.sh 'nemotron|qwen|llama|cohere'
```

The script reports HTTP status, context length and latency. HTTP 200 means the model answered this small test request. 429 means rate limiting; 403 or 404 should be inspected rather than assumed to mean the entire gateway is broken.

## 9. Server-side model and log checks

Models:

```bash
export KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2-)
curl -s localhost:4000/v1/models -H "Authorization: Bearer $KEY" | jq -r '.data[].id'
```

Recent spend/request records (newest first):

```bash
curl -s localhost:4000/spend/logs -H "Authorization: Bearer $KEY" \
  | jq -r '.[:5][] | "\(.startTime)  \(.model_group // .model)  \(.model)"'
```

Routing decisions:

```bash
docker compose logs --since 5m litellm | grep 'routing decision' \
  | grep -oE 'cause=[a-z_]+|tier=[A-Z]+|routed_model=[a-z0-9_-]+' \
  | paste - - - | sort | uniq -c
```

## 10. Security / production cleanup

- Keep `.env` mode `600` and never commit it.
- Revoke any application key pasted into chat, tickets or shared documents during testing.
- Do not expose TEI port 8080 externally; it has no gateway authentication in this lab topology.
- Restrict LiteLLM port 4000 to trusted networks or put it behind your normal ingress/authentication layer.
- Use application-specific Virtual Keys instead of the master key.
- Pin the LiteLLM container image before production. The validated runtime reported LiteLLM `1.106.2`, but the exact matching GHCR image tag was not verified during the test; this bundle therefore leaves `main-stable` with an explicit comment rather than inventing a tag.
- The current OpenRouter models are free test backends. Re-run `scan-free-models.sh` or replace them with your selected paid/production models before a formal class or production deployment.

