# Configuring LiteLLM Semantic Routing and Connecting to Agent Harness

This README documents how to configure LiteLLM running in Docker (Linux) to route SIMPLE and MEDIUM requests to a local llama.cpp server running on a Windows laptop. The connection uses an SSH reverse tunnel so the llama.cpp server does not need to listen directly on the LAN.

## 1. Architecture

```text
                 Hermes Agent (Windows)
                           |
                           | OpenAI-compatible API
                           v
                     LiteLLM Proxy
                           |
              ┌────────────┼────────────┐
              |            |            |
              v            v            v
      1. Local LLM    2. GPU LLM    3. Cloud LLM
         Inference       Inference      Inference
              |            |            |
              v            v            v
        llama.cpp       vLLM on       OpenRouter
        Windows         Intel Arc     Free Models
    Hermes-3-Llama-     Pro B70
      3.1-8B-4bit

```

### 1.1 Configuration Reference

Depending on how user is accessing the LiteLLM proxy, local llama.cpp server (via SYCL0) and B70 GPU vLLM endpoint, network configuration will differ. Some of the steps below are relevant to the moderator's configuration of a reverse tunnel (since llama.cpp server and hermes agent OS is residing in local PC and LiteLLM router and B70 endpoint is residing in remote server) 

Step 3 - 5 is not relevant to the fundamental concept of semantic LLM routing for agentic harness. You may skip it if you are only listening to the moderator's demonstration. 

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

## 3. Verify the Docker Gateway on your LiteLLM/B70 server

The LiteLLM container must connect to the Docker bridge gateway, not to its own loopback address.

Run this command on server terminal. ```module2-litellm-1``` is the name of the docker we started in [Module 2](https://github.com/malcolmchanhaoxian/Intel-SG-Workshop-2026/tree/main/Module%202):

```bash
docker inspect module2-litellm-1 \
  --format '{{range $name, $net := .NetworkSettings.Networks}}network={{$name}} container_ip={{$net.IPAddress}} gateway={{$net.Gateway}}{{println}}{{end}}'
```

Example output:

```text
network=module2_default container_ip=<IPADDRESS> gateway=<IPADDRESS>
```

Record the gateway address. This example uses `172.18.0.1`.

## 4. Configure SSH Reverse Tunnelling

We will initiate a SSH reverse tunnel from our Local Windows PC to the LiteLLM/B70 Server so our LiteLLM router can access the local iGPU model serving.

### 4.1 Back Up the SSH Configuration

On the server side, create a backup:

```bash
sudo cp -a /etc/ssh/sshd_config \
  /etc/ssh/sshd_config.backup-before-gatewayports
```

### 4.2 Configure GatewayPorts on Server

Edit the SSH daemon configuration:

```bash
sudo nano /etc/ssh/sshd_config
```

Set the following directive:

```text
GatewayPorts clientspecified
```

Check for conflicting active `GatewayPorts` directives, including directives later in the file or in included configuration files.

The intended setting is `clientspecified`.

**Do not use `GatewayPorts yes` for this configuration.** It will cause the reverse tunnel to listen on wildcard addresses, including `0.0.0.0:18080` and `[::]:18080`, exposing the listener on all host interfaces.

With `GatewayPorts clientspecified`, the SSH client can request the specific bind address `172.18.0.1`.

### 4.3 Validate and Reload SSH

Validate the SSH configuration:

```bash
sudo sshd -t
```

No output indicates that the syntax check passed.

Reload the SSH service:

```bash
sudo systemctl reload ssh
```

Verify the effective setting:

```bash
sudo sshd -T | grep '^gatewayports '
```

Expected output:

```text
gatewayports clientspecified
```

Do not proceed if the effective setting is different.

### 4.4 Start the Reverse Tunnel from Windows to the B70/LiteLLM server

In PowerShell on Windows, run:

```powershell
ssh -N -T -o ExitOnForwardFailure=yes -R 172.18.0.1:18080:127.0.0.1:8080 username@<SERVERIPADDRESS>
```

Replace the gateway address, SSH username, or Server IP address if your environment differs.

A successful tunnel normally remains running without returning to the PowerShell prompt. This is expected.

Keep this window open while using LiteLLM.

### 4.5 Verify the Tunnel Listener

On server, run:

```bash
ss -ltnp | grep ':18080'
```

The intended listener address is:

```text
172.18.0.1:18080
```

**Security check:** Do not consider the tunnel restricted if the output shows wildcard listeners such as:

```text
0.0.0.0:18080
[::]:18080
```

If it still shows wildcard listeners, stop and correct the effective SSH configuration before continuing.

The tunnel should listen on the Docker gateway address, not on every host interface.

## 5. Test Connectivity Through the Tunnel

### 5.1 Test from the LiteLLM Container

With llama.cpp and the SSH tunnel running, execute this command on server:

```bash
docker exec module2-litellm-1 python3 -c "import urllib.request; print(urllib.request.urlopen('http://172.18.0.1:18080/v1/models', timeout=5).read().decode())"
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

## 6. Configure LiteLLM `config.yaml`

Edit the host-side LiteLLM configuration file:

```text
~/Intel-SG-Workshop-2026/Module 2/config.yaml
```

The current config routes prompts of different nature to different LLM. We have split the prompt type to the below format as explained previously:
```
# SIMPLE / MEDIUM (model_name: default-llm)
# COMPLEX / coding (model_name: coder-llm)
# REASONING (model_name: reasoning-llm)
```

### 6.1 SIMPLE/MEDIUM - Local llama.cpp Backend

Configure `default-llm` as follows:

```yaml
# SIMPLE / MEDIUM: local llama.cpp on Windows via SSH reverse tunnel
- model_name: default-llm
  litellm_params:
    model: openai/Hermes-3-Llama-3.1-8B-4bit
    api_base: http://172.18.0.1:18080/v1
    api_key: none
```

The `api_base` must match the Docker gateway and reverse-tunnel port.

### 6.2 Retain the OpenRouter Backends

Keep the existing COMPLEX and REASONING backends:

```yaml
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

Ensure that `OPENROUTER_API_KEY` remains configured in the server environment. Never put the actual key in this README or commit it to source control.

### 6.3 Preserve the Smart Router Configuration

Keep the existing `smart_router` model and complexity-routing rules. The intended tier mapping is:

```yaml
- model_name: smart_router
  litellm_params:
    model: auto_router/complexity_router
    drop_params: true
    complexity_router_config:
      tiers:
        SIMPLE: default-llm
        MEDIUM: default-llm
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

If the application fails to start, inspect the logs before making additional configuration changes.

## 8. Verify End-to-End Routing

### 8.1 Test SIMPLE or MEDIUM

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

Send a coding-oriented prompt and inspect the corresponding LiteLLM request log.

The expected backend is:

```text
coder-llm
```

This maps to the configured OpenRouter model.

### 8.3 Test REASONING

Send a reasoning-intensive prompt and inspect the request log.

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
