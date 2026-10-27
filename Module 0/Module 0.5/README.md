# Module 0.5: Add a Local Agent with ZeroClaw

This optional module builds on Module 0 by adding an agentic layer to the local Intel AI stack.

```text
User objective
      ↓
ZeroClaw
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

## 1. Start the local model server

Open PowerShell in the `llama.cpp` SYCL directory.

Set your model path.

Example:

```powershell
$Model = "$HOME\Downloads\Qwen3.5-4B-Q4_K_M.gguf"
```

Start the model server:

```powershell
.\llama-server.exe `
    -m $Model `
    -ngl 99 `
    -c 32768 `
    --alias local-agent `
    --port 8080
```

Wait for:

```text
llama_server: model loaded
llama_server: listening on http://127.0.0.1:8080
```

Keep this PowerShell window open.

### Check the API

Open another PowerShell window:

```powershell
Invoke-RestMethod `
    -Uri "http://127.0.0.1:8080/health" `
    -Method Get
```

Expected:

```text
status
------
ok
```

Check the served model:

```powershell
(Invoke-RestMethod `
    -Uri "http://127.0.0.1:8080/v1/models").data |
    Select-Object id
```

Expected:

```text
local-agent
```

---

## 2. Install ZeroClaw

Run:

```powershell
$ver = (Invoke-RestMethod "https://api.github.com/repos/zeroclaw-labs/zeroclaw/releases/latest").tag_name.TrimStart("v")
$dst = "$env:USERPROFILE\.zeroclaw\bin"
$exe = "$dst\zeroclaw.exe"

$current = if (Test-Path $exe) {
    ((& $exe --version 2>$null) |
        Select-String -Pattern '\d+\.\d+\.\d+').Matches.Value
} else {
    ""
}

if ($current -ne $ver) {
    $url = "https://github.com/zeroclaw-labs/zeroclaw/releases/download/v$ver/zeroclaw-x86_64-pc-windows-msvc.zip"

    New-Item -ItemType Directory -Force -Path $dst | Out-Null

    Invoke-WebRequest `
        -Uri $url `
        -OutFile "$env:TEMP\zeroclaw.zip" `
        -UseBasicParsing

    Expand-Archive `
        -Force `
        -Path "$env:TEMP\zeroclaw.zip" `
        -DestinationPath $dst
}

$userPath = :GetEnvironmentVariable("Path", "User")

if (($userPath -split ";") -notcontains $dst) {
    [Environment]::SetEnvironmentVariable(
        "Path",
        "$dst;$userPath",
        "User"
    )
}

if (($env:Path -split ";") -notcontains $dst) {
    $env:Path = "$dst;$env:Path"
}
```

Verify:

```powershell
zeroclaw --version
```

ZeroClaw is installed under:

```text
%USERPROFILE%\.zeroclaw\bin
```

---

## 3. Add llama.cpp as a ZeroClaw provider

Create a local llama.cpp provider:

```powershell
zeroclaw config init providers.models.llamacpp.local
```

Point it to `llama-server`:

```powershell
zeroclaw config set `
    providers.models.llamacpp.local.uri `
    "http://127.0.0.1:8080"
```

Set the API model name:

```powershell
zeroclaw config set `
    providers.models.llamacpp.local.model `
    "local-agent"
```

For a text-only model:

```powershell
zeroclaw config set `
    providers.models.llamacpp.local.vision `
    false
```

Review the provider:

```powershell
zeroclaw config list `
    --filter providers.models.llamacpp.local
```

Confirm:

```text
uri    = http://127.0.0.1:8080
model  = local-agent
vision = false
```

---

## 4. Create the agent

Create an agent called `workshop`:

```powershell
zeroclaw agents create workshop
```

Initialize its default risk profile:

```powershell
zeroclaw config init risk_profiles.workshop
```

Connect the agent to the local llama.cpp provider:

```powershell
zeroclaw config set `
    agents.workshop.model_provider `
    "llamacpp.local"
```

Assign its risk profile:

```powershell
zeroclaw config set `
    agents.workshop.risk_profile `
    "workshop"
```

Review the agent:

```powershell
zeroclaw config list `
    --filter agents.workshop
```

Look for:

```text
model_provider = llamacpp.local
risk_profile   = workshop
```

---

## 5. Start ZeroClaw

Start an interactive agent session:

```powershell
zeroclaw agent -a workshop
```

You are now interacting with:

```text
ZeroClaw
    ↓
llamacpp.local
    ↓
llama-server
    ↓
Local LLM
    ↓
SYCL / DPC++
    ↓
Level Zero
    ↓
Intel Graphics
```

Try a normal request first:

```text
Explain in one paragraph what SYCL is.
```

Then give the agent a task that requires it to use available capabilities rather than simply answer a question.

The exact response and tools selected depend on the model and task.

---

## 6. Watch the inference stack

Keep the `llama-server` window visible while interacting with ZeroClaw.

You should see requests being processed by the same local model server used in Module 0.

Typical timing output includes:

```text
prompt eval time
eval time
total time
```

The application layer has changed:

```text
Module 0

User
 ↓
llama-cli / llama-server
```

to:

```text
Module 0.5

User objective
 ↓
ZeroClaw agent
 ↓
llama-server
```

But the Intel inference path underneath remains:

```text
llama.cpp
    ↓
SYCL / DPC++
    ↓
Level Zero
    ↓
Intel Graphics
```

---

## 7. Switching inference infrastructure later

The `workshop` agent references:

```text
llamacpp.local
```

rather than owning the inference endpoint itself.

Today:

```text
workshop
    ↓
llamacpp.local
    ↓
Intel AI PC
```

Later modules can introduce a different model provider while keeping the agent concept unchanged:

```text
workshop
    ↓
model provider
    ↓
different inference infrastructure
```

This separation between the agent and model provider will become important when the workshop moves from local inference to larger GPU serving and routing.

---

## Completion check

Module 0.5 is complete when:

- ZeroClaw is installed
- `llama-server` is running
- `llamacpp.local` points to the local endpoint
- the `workshop` agent uses `llamacpp.local`
- `zeroclaw agent -a workshop` starts successfully
- the agent can interact with the locally served model
- activity is visible in the `llama-server` console

You now have:

```text
Agentic application
       ↓
ZeroClaw
       ↓
OpenAI-compatible model service
       ↓
llama-server
       ↓
SYCL / DPC++
       ↓
Level Zero
       ↓
Intel Graphics
```
