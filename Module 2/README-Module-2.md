# Module 2 — Xeon Semantic / Complexity Routing

In **Module 0** and **Module 1**, we created separate LLM serving endpoints with different levels of compute and serving complexity.

Both endpoints expose large-context LLM inference that our **Hermes agent harness** can consume.

Until now, however, Hermes has had to connect to a specific LLM endpoint.

As we add more inference options, this creates a new problem:

> **Who decides which model Hermes should use?**

Not every request needs to be sent to the largest or most expensive model.

A simple request may be handled perfectly well by a model running locally on the PC or on an edge GPU. Other requests may benefit from a coding-oriented model or a larger reasoning model. Cloud inference should therefore be another resource in our inference pool, rather than the default destination for every prompt.

In this module, we will consolidate these separate inference APIs behind **LiteLLM** and expose a single application-facing model:

```text
smart_router
```

Hermes no longer needs to decide which backend model to call.

Instead:

```text
                             +--> Local / PC LLM
                             |
Hermes --> smart_router -----+--> Edge GPU LLM
                             |
                             +--> Cloud LLM
                                  when required
```

The application sees **one API**. The infrastructure decides **which LLM should handle the request**.
This lets us start thinking about inference as a workload-placement problem:

> **Run each request on an appropriate model and compute resource instead of automatically consuming cloud tokens for every request.**

In this lab, we will build that decision layer using:

- `BAAI/bge-base-en-v1.5` served by Hugging Face TEI on Intel Xeon CPU
- LiteLLM AI Gateway / Proxy
- LiteLLM `auto_router/complexity_router`
- BGE semantic keyword matching plus LiteLLM heuristic fallback
- OpenRouter model backends
- A single client-facing model name: `smart_router`

Most importantly, we will **build and modify the routing policy ourselves in `config.yaml`**.

By the end of the lab, Hermes will no longer need to know whether a prompt is handled locally, at the edge, or by a cloud model.

It will simply call:

```text
smart_router
```

---

## Files

The Module 2 lab contains:

- `docker-compose.yml` — TEI, PostgreSQL and LiteLLM
- `config.yaml` — model definitions and routing policy
- `.env.example` — environment variable template
- `make-env.sh` — safely creates `.env` and matching PostgreSQL credentials
- `test-stack.sh` — layer-by-layer health and routing test
- `scan-free-models.sh` — tests current OpenRouter `:free` models
- `route-eval.sh` — routing-quality evaluator
- `tests/prompts.txt` — 15 labelled learner prompts using `TIER|prompt`

---

## 0. Prerequisites (Ubuntu 24.04)

By this stage, you should have the prerequisites all cleared in previous Module. Skip to Part 1.
For the uninitiated, please ensure Docker is installed.

Install Docker Engine / Compose using Docker's official Ubuntu repository. Also install `jq`, `curl`, and `openssl`.

After Docker is installed, add your user to the `docker` group and reconnect the SSH session (or use `newgrp docker`). Verify:

```bash
docker --version
docker compose version
docker run --rm hello-world
```

Clone the repo
```
cd ~
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/malcolmchanhaoxian/Intel-SG-Workshop-2026.git
```

## 1. Configure secrets

```bash
cd ~/Intel-SG-Workshop-2026/"Module 2"
bash make-env.sh
```

The script asks only for the OpenRouter key, then generates the LiteLLM master key, salt key and PostgreSQL password. It writes `.env` with mode `600` and ensures the password in `DATABASE_URL` matches `POSTGRES_PASSWORD`.

Never change `LITELLM_SALT_KEY` after the database begins storing encrypted secrets.


### 1.1 Semantic Complexity Routing - From multiple endpoints to one inference service

Before starting the containers, let's understand what we are building.

In Modules 0 and 1, the application effectively had to know which LLM endpoint it wanted:

```text
Hermes ----------> LLM Endpoint A          OR          Hermes ----------> LLM Endpoint B
```

That works when we only have one or two inference options.
But as our infrastructure grows, we may have:

```text
Local PC model  |  Edge GPU model  |  Large edge model  |  Coding model  |  Reasoning model  |  Cloud API
```

We do not want Hermes to contain logic such as:

```text
if simple:          if coding:            if difficult:
    use model A        use model B            use model C
```

That couples the application to the infrastructure. Instead, we are going to introduce an inference gateway:

```text
                             +--> Model A
                             |
Hermes --> smart_router -----+--> Model B
                             |
                             +--> Model C
```

From Hermes' perspective there is now only:

```text
smart_router
```

### 1.1 Docker Compose — CPU Embedding Inference

Conceptually, LiteLLM uses BGE embeddings to match incoming prompts against configured semantic phrases, with heuristic complexity scoring as a fallback.

```text
Incoming Prompt --> LiteLLM Router --> BGE Embedding Model --> Semantic comparison --> Routing decision
                                          on Xeon CPU
```

We are therefore using the Xeon not simply as another place to run a generative LLM. The CPU is participating in the **inference decision layer**.

From `docker-compose.yml`:

```yaml
tei:
  image: ghcr.io/huggingface/text-embeddings-inference:cpu-1.9
  command: --model-id BAAI/bge-base-en-v1.5
  cpuset: "0-7"
```

Runs the BGE embedding model using TEI on the Xeon CPU, pinned to cores `0–7`. LiteLLM uses this service to generate prompt embeddings for semantic matching. 

Now we will go to `config.yaml`. Look for `match_threshold`.
This controls the configured semantic-match threshold for this lab.

```yaml
match_threshold: 0.7
```

**Semantic keyword matching rules**

These example phrases are configured in `config.yaml`:

```yaml
keyword_tier_rules:
  - tier: SIMPLE
    keywords:
      - "hello"
      - "what is the capital of France"
      - "summarize this paragraph in one line"
      - "translate this sentence into Malay"
      - "rewrite this email to sound more polite"

  - tier: COMPLEX
    keywords:
      - "write a python function that parses a CSV file"
      - "fix this bug in my javascript code"
      - "why does my bash script throw a syntax error"
      - "convert this SQL query to pandas"
      - "write a dockerfile for a fastapi app"

  - tier: REASONING
    keywords:
      - "compare the trade-offs of three architectures and recommend one"
      - "plan a migration strategy with risks and mitigations"
      - "design a distributed system for a million requests per second"
      - "analyze this business case and build a decision framework"
```

BGE embeddings enable matching based on semantic similarity rather than requiring exact wording.

**Tier-to-model mapping**

```yaml
tiers:
  SIMPLE: default-llm
  MEDIUM: default-llm
  COMPLEX: coder-llm
  REASONING: reasoning-llm
```
`MEDIUM` has no explicit semantic keyword rule in this configuration. It maps to `default-llm` and may be selected by the heuristic complexity scorer.

The current lab configuration maps the abstract model names to OpenRouter models.

| Tier | Router model | OpenRouter backend |
|---|---|---|
| SIMPLE | `default-llm` | `nvidia/nemotron-3.5-lightning:free` |
| MEDIUM | `default-llm` | `nvidia/nemotron-3.5-lightning:free` |
| COMPLEX | `coder-llm` | `cohere/north-mini-code:free` |
| REASONING | `reasoning-llm` | `nvidia/nemotron-3-ultra-550b-a55b:free` |

**In summary:** TEI generates embeddings on the Xeon CPU; LiteLLM uses semantic matching and heuristic fallback to select a tier and route each request to the corresponding model.

```yaml
model_list:
  # BGE embedding model served locally by TEI on Xeon.
  - model_name: bge-embed
    litellm_params:
      model: openai/BAAI/bge-base-en-v1.5
      api_base: http://tei:80/v1
      api_key: none

  # SIMPLE / MEDIUM
  - model_name: default-llm
    litellm_params:
      model: openai/Hermes-3-Llama-3.1-8B-4bit
      api_base: http://172.18.0.1:18080/v1
      api_key: none

  # COMPLEX / coding
  - model_name: coder-llm
    litellm_params:
      model: openrouter/cohere/north-mini-code:free
      api_key: os.environ/OPENROUTER_API_KEY

  # REASONING
  - model_name: reasoning-llm
    litellm_params:
      model: openrouter/nvidia/nemotron-3-ultra-550b-a55b:free
      api_key: os.environ/OPENROUTER_API_KEY
```


### 1.2 Modify the Semantic Routing Logic
For this lab, `config.yaml` has used OpenRouter models to help us verify that the routing logic works.
But that is **not the final architecture we are trying to build**.

In the previous modules, we already created our own LLM serving endpoints:
- **Module 0 / local inference:** `llama.cpp` server running via `SYCL0`
- **Module 1 / edge inference:** vLLM running on the Intel Arc Pro B70 GPU

We are now going to bring those endpoints together.

Instead of sending SIMPLE, MEDIUM and COMPLEX requests to three different OpenRouter models, we will edit `config.yaml` so that LiteLLM routes requests to the infrastructure we have already deployed.

Our target architecture is:

```text
                                      +--> SIMPLE / MEDIUM
                                      |      |
                                      |      +--> llama.cpp / SYCL0
                                      |
Hermes --> LiteLLM --> smart_router --+--> COMPLEX
                                      |      |
                                      |      +--> B70 / vLLM
                                      |
                                      +--> REASONING
                                             |
                                             +--> Cloud LLM
```

### Llama.cpp SYCL0 
In Module 0, we started a Llama.cpp server locally on the laptop and we can extract the model structure.

```
$Models = Invoke-RestMethod `
    -Uri "http://172.18.0.1:18080/v1/models" `
    -Method Get

$Models.data |
    Select-Object id, object
```

The response should contain the served model name:
```
Hermes-3-Llama-3.1-8B-4bit
```

### B70 vLLM
And you can also quickly extract the model structure of the vLLM endpoint on the GPU server.
```
curl.exe -sS http://GPU_SERVER_IP:8001/v1/models
```
The response should contain the served model name:
```
Qwen3.8-27B
```

### Update your completed model configuration

At this point, your `model_list` should conceptually contain:

```yaml
model_list:
  # BGE embedding model served locally by TEI on Xeon.
  - model_name: bge-embed
    litellm_params:
      model: openai/BAAI/bge-base-en-v1.5
      api_base: http://tei:80/v1
      api_key: none

  # SIMPLE / MEDIUM
  - model_name: default-llm
    litellm_params:
      model: openai/Hermes-3-Llama-3.1-8B-4bit
      api_base: http://172.18.0.1:18080/v1
      api_key: none

  # COMPLEX / coding
  - model_name: coder-llm
    litellm_params:
      model: Qwen3.8-27B
      api_base: http://GPU_SERVER_IP:8001/v1
      api_key: none

  # REASONING
  - model_name: reasoning-llm
    litellm_params:
      model: openrouter/nvidia/nemotron-3-ultra-550b-a55b:free
      api_key: os.environ/OPENROUTER_API_KEY
```

## 2. Start the stack

```bash
docker compose up -d
docker compose ps
docker compose logs -f litellm
```

<img width="657" height="516" alt="image" src="https://github.com/user-attachments/assets/3818585e-462e-4361-adee-d06f77640c62" />


Press Ctrl+C after LiteLLM is listening. This stops only the log view.

Services:
- TEI: host port 8080
- LiteLLM: host port 4000
- PostgreSQL: internal Docker network only

TEI is pinned to Xeon cores `0-7` in `docker-compose.yml`. Adjust `cpuset` to match the intended CPU allocation.

## 3. Test each layer

```
bash ./test-stack.sh
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
  -d '{"model":"smart_router","max_tokens":1000,"messages":[{"role":"user","content":"Write a Python function to reverse a string. Include the complete function and one example."}]}' \
  | tee /tmp/smart-router-test.json \
  | jq '{finish_reason: .choices[0].finish_reason, content: .choices[0].message.content, error: .error}'
```

Reasoning-capable backends can consume much of the completion budget in reasoning tokens. A 100-token test produced `finish_reason=length` before returning answer content during validation, while a 1000-token request returned the answer. For learning tests use `max_tokens: 1000` or inspect the model's reasoning/token behavior explicitly.

## 5. LiteLLM UI

Access LiteLLM UI Dashboard
```http://<gateway-host>:4000/ui```

<img width="2556" height="1262" alt="image" src="https://github.com/user-attachments/assets/243cfa96-b71a-4a35-888b-b810f716b04a" />

## 6. Create application keys

In the LiteLLM UI create a Virtual Key with:

- Models: `smart_router` only
- Key type: AI API
- Alias: e.g. `test-app`

This prevents an application from directly bypassing routing through `default-llm`, `coder-llm`, `reasoning-llm`, or `bge-embed`.

Please keep the Virtual Key safe with you as you will need it to configure your Agentic Harness in a later module.

## 7. Evaluate routing quality

```
bash ./route-eval.sh
```

The evaluator intentionally uses `TIER|prompt` rather than tabs so browser SSH copy/paste cannot silently corrupt the input format.

What is the score you got?

## 8. Scan currently available OpenRouter free models

Free model availability and provider health can change. Test the current free inventory instead of assuming a free model is callable:

```
bash ./scan-free-models.sh
```

The script reports HTTP status, context length and latency. HTTP 200 means the model answered this small test request. 429 means rate limiting; 403 or 404 should be inspected rather than assumed to mean the entire gateway is broken.

Make changes to existing model routing decisions
```
vim config.yaml
```

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

