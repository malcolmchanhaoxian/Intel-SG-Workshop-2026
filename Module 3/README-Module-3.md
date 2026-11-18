# Configuring LiteLLM Semantic Routing and Connecting to Agent Harness

This README documents how to configure LiteLLM running in Docker inside the assigned student VM to route requests across the learner's Windows laptop, the dedicated Intel Arc Pro B70, and a cloud reasoning model.

SIMPLE requests are routed to the local Hermes model running through llama.cpp on the Windows laptop. MEDIUM and COMPLEX requests are routed to SEA-LION served by vLLM on the student's dedicated B70. REASONING requests are routed to the configured cloud reasoning backend.

An SSH reverse tunnel allows the LiteLLM container inside the student VM to securely reach the llama.cpp server on the learner's Windows laptop without exposing llama.cpp directly on the LAN.

In the previous modules, we already created our own LLM serving endpoints and we will bring those endpoints together.
- **Module 0 / local inference:** `llama.cpp` server running via `SYCL0`
- **Module 1 / edge inference:** vLLM running on the Intel Arc Pro B70 GPU

## 1. Architecture

```text
                       Hermes Agent
                     Windows Laptop
                          |
                          | 
                          v
                    LiteLLM Proxy
                  inside studentNN
                          |
            +-------------+-------------+
            |             |             |
            v             v             v
         SIMPLE      MEDIUM/COMPLEX   REASONING
            |             |             |
            v             v             v
         Hermes        SEA-LION      OpenRouter
       llama.cpp         vLLM          Cloud
       Windows            |
                          v
                   Intel Arc Pro B70

```

### 1.1 Configuration Reference

LiteLLM, TEI, PostgreSQL, and the B70 vLLM endpoint run inside the assigned studentNN VM. Hermes and llama.cpp run on the Windows laptop. The training host is used as the SSH jump host between the learner laptop and the assigned student VM.


## 2. Start llama.cpp on Windows Powershell
You should have your existing llama.cpp server open based on [Module 0](https://github.com/malcolmchanhaoxian/Intel-SG-Workshop-2026/tree/main/Module%200)

Keep this PowerShell window open while using the local model.

### 2.2 Verify the Local Model Endpoint

Open a second PowerShell window and run:

```powershell
Invoke-RestMethod "http://127.0.0.1:8080/v1/models"
```

The response should include:

```text
Hermes-3-Llama-3.1-8B-4bit
```

If this request fails, resolve the llama.cpp startup issue before proceeding.

## 3. Verify the Docker Gateway on your Student VM (LiteLLM/B70)

The LiteLLM container must connect to the Docker bridge gateway, not to its own loopback address.

Your existing docker in [Module 2](https://github.com/malcolmchanhaoxian/Intel-SG-Workshop-2026/tree/main/Module%202) ```inspect module2-litellm-1``` command works, but we now know exactly what information we need:

```bash
GATEWAY=$(docker network inspect module2_default \
  --format '{{(index .IPAM.Config 0).Gateway}}')

echo "$GATEWAY"
```

Example output:

```text
172.18.0.1
```

## 4. Configure SSH Reverse Tunnelling

We will create an SSH reverse tunnel from the Windows laptop to the assigned student VM. This makes the laptop-hosted Hermes/llama.cpp endpoint reachable from the LiteLLM container inside the student VM. Port 18080 is the workshop's chosen reverse-tunnel port on the student VM. It forwards to the llama.cpp server running on Windows at 127.0.0.1:8080.

In PowerShell on Windows, run:

```powershell
ssh -N -T `
  -J sparkle@<TRAINING_HOST_IP> `
  -o ExitOnForwardFailure=yes `
  -R 172.18.0.1:18080:127.0.0.1:8080 `
  intel@student01
```

Replace:
- 172.18.0.1 with the Docker gateway discovered on your student VM in Part 3.
- <TRAINING_HOST_IP> with the training host IP provided by the instructor.
- student01 with your assigned student VM name.

A successful tunnel normally remains running without returning to the PowerShell prompt. This is expected.
Keep this window open while using LiteLLM.

### Verify the Tunnel Listener

On the VM, run:

```bash
sudo ss -lntp | grep ':18080'
```

The intended listener address is:

```text
LISTEN 0 128 172.18.0.1:18080 0.0.0.0:* users:(("sshd",...))
```

**Security check:** Do not consider the tunnel restricted if the output shows wildcard listeners such as:

```text
0.0.0.0:18080
[::]:18080
```

If it still shows wildcard listeners, stop and correct the effective SSH configuration before continuing.
The tunnel should listen on the Docker gateway address, not on every host interface.

## 5. A Series of Smoke Tests... 

### 5.1 Test Tunnel Connectivity from Windows to Student VM 

With llama.cpp and the SSH tunnel running, open a new terminal for your student VM and execute:

```bash
GATEWAY=$(docker network inspect module2_default \
  --format '{{(index .IPAM.Config 0).Gateway}}')

echo "$GATEWAY"

curl -s "http://${GATEWAY}:18080/v1/models" | jq
```

The response should contain the local model alias:

```text
Hermes-3-Llama-3.1-8B-4bit
```

This is the key connectivity test because it verifies that the LiteLLM container can reach the Windows model through the tunnel.

### 5.2 If the Test Fails

Check the following:

1. The llama.cpp server is still running on Windows.
2. The Windows SSH reverse tunnel is still running.
3. The SSH daemon is configured with `GatewayPorts clientspecified`.
4. The listener is bound to the intended Docker gateway address.
5. The gateway address matches the one reported by `docker inspect`.
6. Port `18080` is not blocked by an applicable host firewall rule.

Repeat the container connectivity test after correcting the issue.

### 5.3 Test the tunnel from the inside the LiteLLM Container

```
docker exec module2-litellm-1 \
  python -c "
import urllib.request
print(
    urllib.request.urlopen(
        'http://${GATEWAY}:18080/v1/models',
        timeout=5
    ).read().decode()
)
"
```

The response should again contain the local model alias:

```text
Hermes-3-Llama-3.1-8B-4bit
```

### 5.4 Test Actual Hermes Inference

Don't stop at /v1/models. Verify actual generation:

```
curl -s "http://${GATEWAY}:18080/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Hermes-3-Llama-3.1-8B-4bit",
    "messages": [
      {
        "role": "user",
        "content": "Reply exactly: reverse tunnel passed"
      }
    ],
    "temperature": 0,
    "max_tokens": 32
  }' | jq -r '.choices[0].message.content'
```

Expected:
```
reverse tunnel passed
```

### What We Have Proven 

At this point:

```
Windows llama.cpp
127.0.0.1:8080
        ^
        |
     SSH -R
        |
Student VM
<DockerGateway>:18080
        ^
        |
        |
LiteLLM container
```

## 6. Configure LiteLLM `config.yaml`

Edit the host-side LiteLLM configuration file using your preferred STFP editor:

```/home/intel/Intel-SG-Workshop-2026/Module 2/config.yaml```

Before editing, make a backup:

```shell
cd ~/Intel-SG-Workshop-2026/"Module 2"
cp config.yaml config.yaml.before-module3
```

The Docker gateway discovered in Part 5 is still available in this terminal as:

```echo "$GATEWAY"```

Example:
```172.18.0.1```

The current config routes prompts of different nature to different LLM. We have split the prompt type to the below format as explained previously:
```
# SIMPLE (model_name: default-llm)
# MEDIUM / COMPLEX (model_name: coder-llm)
# REASONING (model_name: reasoning-llm)
```

### 6.1.1 SIMPLE - Local llama.cpp Backend

Configure `default-llm` as follows:

```yaml
# SIMPLE: local Hermes on Windows via SSH reverse tunnel
- model_name: default-llm
  litellm_params:
    model: openai/Hermes-3-Llama-3.1-8B-4bit
    api_base: http://172.18.0.1:18080/v1
    api_key: none
```

The `api_base` must match the Docker gateway and reverse-tunnel port.
**Important**: replace 172.18.0.1 with the Docker gateway discovered on the student's VM if it is different.

### 6.1.2 MEDIUM / COMPLEX - vLLM on B70 Edge Server

LiteLLM router will need to reach the vLLM endpoint from within the container gateway. So let's test this:

```
docker exec module2-litellm-1 \
  python -c "
import urllib.request
print(
    urllib.request.urlopen(
        'http://${GATEWAY}:8001/v1/models',
        timeout=5
    ).read().decode()
)
"
```
The response should contain the served model name:
```
Qwen-SEA-LION-v4.5-27B-IT-4bit
```

Configure `coder-llm` as follows:

```yaml
# MEDIUM / COMPLEX: SEA-LION on the student's dedicated B70
- model_name: coder-llm
  litellm_params:
    model: openai/Qwen-SEA-LION-v4.5-27B-IT-4bit
    api_base: http://172.18.0.1:8001/v1
    api_key: none
```

You can keep or change the OpenRouter reasoning backend per your own liking.

## 6.2 Final Model List

At this point, your `model_list` should conceptually contain:

```yaml
model_list:

  # Embeddings: local TEI service
  - model_name: bge-embed
    litellm_params:
      model: openai/BAAI/bge-base-en-v1.5
      api_base: http://tei:80/v1
      api_key: none

  # SIMPLE: Windows Hermes through SSH reverse tunnel
  - model_name: default-llm
    litellm_params:
      model: openai/Hermes-3-Llama-3.1-8B-4bit
      api_base: http://172.18.0.1:18080/v1
      api_key: none

  # MEDIUM / COMPLEX: SEA-LION on student B70
  - model_name: coder-llm
    litellm_params:
      model: openai/Qwen-SEA-LION-v4.5-27B-IT-fp8
      api_base: http://172.18.0.1:8001/v1
      api_key: none

  # REASONING: cloud
  - model_name: reasoning-llm
    litellm_params:
      model: openrouter/nvidia/nemotron-3-ultra-550b-a55b:free
      api_key: os.environ/OPENROUTER_API_KEY```

**Important**: The example uses 172.18.0.1. Replace both occurrences with the Docker gateway discovered on your assigned student VM.

### 6.3 Preserve the Smart Router Configuration

Keep the existing `smart_router` model and complexity-routing rules. The intended tier mapping is:

```yaml
- model_name: smart_router
  litellm_params:
    model: auto_router/complexity_router
    drop_params: true
    complexity_router_config:
      max_tokens_from_tier_model: false

      tiers:
        SIMPLE: default-llm
        MEDIUM: coder-llm
        COMPLEX: coder-llm
        REASONING: reasoning-llm
      semantic_keyword_matching: true
      embedding_model: bge-embed
      match_threshold: 0.7
      # Keep the existing keyword_tier_rules unchanged.
    complexity_router_default_model: default-llm
```

This is an excerpt for the relevant model entry. Preserve the actual `keyword_tier_rules` and all unrelated configuration entries, including `bge-embed`, `router_settings`, and `general_settings`.

## 7. Restart LiteLLM

After saving the updated configuration, restart only the LiteLLM container:

```bash
cd ~/Intel-SG-Workshop-2026/"Module 2"

docker compose restart litellm
docker restart module2-litellm-1
```

Check the startup logs:

```bash
docker logs --since 3m module2-litellm-1 2>&1 | tail -40
```

Look for:

```text
Application startup complete.
Uvicorn running on http://0.0.0.0:4000
```

### Verify LiteLLM health:

```
curl -s http://127.0.0.1:4000/health/readiness | jq
```

Expected:

```json
{
"status": "healthy",
"db": "connected"
}
```

If LiteLLM has only just restarted, it may need a few seconds before the readiness endpoint responds.

### Verify LiteLLM Model Registration
This can be done on the LiteLLM UI as well.

Load the LiteLLM master key:

```
export KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2-)
```

Then:

```
curl -s http://127.0.0.1:4000/v1/models \
-H "Authorization: Bearer $KEY" \
| jq -r '.data[].id'
```

Verify the important aliases are present:
```
smart_router
default-llm
coder-llm
reasoning-llm
bge-embed
```

## 8. Connect to Hermes

Keep the existing LiteLLM/vLLM powershell tunnel to your Student VM active 

```
ssh -N -T `
  -J intel@<TRAINING_HOST_IP> `
  -o ExitOnForwardFailure=yes `
  -L 4000:127.0.0.1:4000 `
  -L 8001:127.0.0.1:8001 `
  intel@student01
```

```powershell
hermes model
```

Configure:

```text
Provider:
Custom / OpenAI-compatible

API Mode:
Chat Completions

Base URL:
http://127.0.0.1:4000/v1

Model:
smart_router

API Key:
<LiteLLM Virtual Key>

Context Length:
64000
```

### Model Endpoint Name

```text
Display name [Local (127.0.0.1:8080)]: LiteLLM Smart Router
```

### Reasoning

For the local LLM on laptop, let's skip reasoning:

```
 Select reasoning effort:  (○)  8. Disable reasoning

```

### Validate the configuration:

```powershell
hermes config check
```

If everything has been configured successfully, the config check should return the following response:
```text
📋 Configuration Status

  Config version: 51 ✓

  Required:

```

### Start and Test the Hermes agent

Start the interactive Hermes CLI:

```powershell
hermes
```

### 8.1 Test SIMPLE

From Hermes on Windows, send a simple prompt, such as:

```text
Explain in two sentences why the sky appears blue.
```

Hermes should send the request to LiteLLM using the client-facing model name:

```text
smart_router
```

In the LiteLLM dashboard, inspect the request logs and confirm that the actual backend is `default-llm` or the local llama.cpp model.

### 8.2 Test COMPLEX

Send a coding-oriented prompt with a vulnarable code that does double withdrawal:

```
Analyze this Python withdrawal implementation for correctness under concurrent requests.
Identify the race condition, explain the time-of-check/time-of-use problem, and provide a thread-safe implementation.
Then explain why an in-process lock is insufficient when multiple application instances share the same PostgreSQL account database,
and provide a transaction-safe database approach.

import time

def withdraw_money(account, amount):
    # 1. TIME OF CHECK
    if account['balance'] >= amount:
        print("Funds approved!")
        
        # Simulating a tiny network delay or system lag
        time.sleep(0.1) 
        
        # 2. TIME OF USE
        account['balance'] -= amount
        print(axis = f"Withdrew ${amount}. New balance: ${account['balance']}")
    else:
        print("Declined: Insufficient funds.")
```

The expected backend is:

```text
coder-llm
```

This maps to the configured OpenRouter model.

### 8.3 Test REASONING

Send a reasoning-intensive prompt and inspect the request log.

```
Compare active-active and active-passive designs for a multi-region payment platform. Analyze the trade-offs and recommend one architecture.
```

The expected backend is:

```text
reasoning-llm
```

This maps to the configured OpenRouter reasoning model.

A successful response by itself does not prove which backend handled a request. Use LiteLLM request logs and the llama.cpp server logs to confirm routing.

## 9. Operational Notes

### 9.1 Required Running Processes

The following must be running for local inference to work:

1. The Windows `llama-server.exe` process.
2. The Windows SSH reverse-tunnel process.
3. The LiteLLM Docker container on Server.
4. Hermes configured to use the LiteLLM `smart_router` model.

### 9.2 Laptop Sleep or Network Changes

If Windows sleeps, changes networks, or disconnects from Server, the SSH tunnel may stop working.

Restart the tunnel after the laptop wakes or reconnects. Confirm connectivity with the `/v1/models` test before retrying Hermes.

### 9.3 Docker Gateway Changes

If the Docker network is recreated, the gateway address may change.

Check the gateway with:

```bash
docker inspect module2-litellm-1 \
  --format '{{range $name, $net := .NetworkSettings.Networks}}network={{$name}} gateway={{$net.Gateway}}{{println}}{{end}}'
```

If it differs, update both:

- The Windows SSH command's reverse-forward bind address.
- The `default-llm` `api_base` in LiteLLM `config.yaml`.

### 9.4 SSH Recovery

If you need to restore the SSH configuration backup, do so carefully:

```bash
sudo cp -a /etc/ssh/sshd_config.backup-before-gatewayports /etc/ssh/sshd_config
sudo sshd -t
sudo systemctl reload ssh
```

Only restore the backup if appropriate for your current SSH configuration. Keep the existing administrative session open until you have confirmed access is still working.
---

**Final topology:** Hermes Agent → LiteLLM `smart_router` on Server → local llama.cpp through the SSH reverse tunnel for SIMPLE/MEDIUM, with OpenRouter retained for COMPLEX/REASONING.
