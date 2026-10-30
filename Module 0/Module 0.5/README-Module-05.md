# Module 0.5: Add a Local Agent with Hermes 

<img width="1200" height="630" alt="image" src="https://github.com/user-attachments/assets/30169d38-eb2d-44ff-81d8-5dd7709d83ac" />

This optional module builds on Module 0 by adding an agentic layer to the local Intel AI stack.

```text
User objective
      ↓
Hermes Agent
      ↓
Local LLM
      ↓
llama-server
      ↓
SYCL / DPC++
      ↓
Level Zero
      ↓
Intel Graphics
```

Instead of interacting directly with `llama.cpp`, you will give an agent a task and allow the model to decide how to complete it.

---

## Requirements

Complete Module 0 first.

You should already have:

- Windows 11
- Intel graphics detected by the SYCL backend
- the Windows x64 SYCL build of `llama.cpp`
- a suitable GGUF model
- a working `llama-server`

Performance will vary by Intel GPU, driver, model, quantization, context size and system memory.

---

## 1. Get the local model server details

### Check the API

Open another PowerShell window:

Check the served model:

```powershell
(Invoke-RestMethod `
    -Uri "http://127.0.0.1:8080/v1/models").data |
    Select-Object id
```

Expected (Eg):

```text
Hermes-3-Llama-3.1-8B-4bit
```

---

## 2. Install Hermes Agent

Run the Hermes Windows installer without launching the interactive setup:

```powershell
& ([scriptblock]::Create(
    (irm https://hermes-agent.nousresearch.com/install.ps1)
)) -NonInteractive
```

The `-NonInteractive` option installs Hermes while skipping setup and gateway stages that require user input.

After installation completes, close PowerShell and open a new PowerShell window.

Verify the installation:

```powershell
hermes --version
```

Run the built-in diagnostics:

```powershell
hermes doctor
```

Hermes is now installed. We will configure only the model connection required for this workshop.

---

## 3. Configure the local model

Run:

```powershell
hermes model
```

Choose the option for:

```text
Custom / OpenAI-compatible endpoint
```

Based on the API endpoint we configured in Step 1 - we will configure the Hermes model:

### Base URL

```text
http://127.0.0.1:8080/v1
```

### Model

```text
Hermes-3-Llama-3.1-8B-4bit
```


### API key

The `llama-server` used in this module is running locally without API authentication.

### Context length

When prompted for the context length, use: ```64000```.
Hermes has a minimum floor of 64000 tokens for context window.

### Validate the configuration:

```powershell
hermes config check
```

## 4. Start and Test the Hermes agent

Start the interactive Hermes CLI:

```powershell
hermes
```

Keep the `llama-server` PowerShell window visible.

Run a simple chat request:

```powershell
"What is 2 + 2?"
```

A successful response confirms:

```text
Hermes
   ↓
OpenAI-compatible API
   ↓
llama-server
   ↓
llama.cpp
   ↓
SYCL / DPC++
   ↓
Level Zero
   ↓
Intel Graphics
```

You should also see the request being processed in the `llama-server` console.

---

## Completion Check

Module 0.5 is complete when:

- Hermes is installed successfully
- `hermes --version` works
- `hermes doctor` reports no blocking issue
- Hermes is configured with the local OpenAI-compatible endpoint
- the configured model matches the alias exposed by `llama-server`
- the interactive `hermes` session starts successfully
- `hermes` console chat returns response
- model activity is visible in the `llama-server` console
```
