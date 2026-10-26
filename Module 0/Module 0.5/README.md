# Module 0.5 Validation: ZeroClaw Agent on Intel Graphics

## Target stack

```text
ZeroClaw
    ↓
Qwen3.5-4B Q4_K_M
    ↓
llama-server
    ↓
llama.cpp SYCL
    ↓
Level Zero
    ↓
Intel Graphics
```

## 1. Validate the Intel GPU path

From the llama.cpp Windows SYCL directory:

```powershell
.\llama-cli.exe --list-devices
```

Confirm an Intel SYCL device is listed.

Then:

```powershell
.\llama-bench.exe --list-devices
```

Look for:

```text
GGML_SYCL_SUPPORT_LEVEL_ZERO_API: yes
GGML_SYCL_USE_LEVEL_ZERO_API: 1
[level_zero:gpu:0]
```

---

## 2. Benchmark Qwen3.5-4B

Place:

```text
Qwen3.5-4B-Q4_K_M.gguf
```

in the Downloads folder.

Set the path:

```powershell
$Model4B = "$HOME\Downloads\Qwen3.5-4B-Q4_K_M.gguf"
```

Run:

```powershell
.\llama-bench.exe `
    -m $Model4B `
    -ngl 99
```

Record:

```text
pp512: __________ t/s
tg128: __________ t/s
```

There is no target score. We want a Panther Lake baseline.

---

## 3. Start the model server

```powershell
.\llama-server.exe `
    -m $Model4B `
    -ngl 99 `
    -c 32768 `
    --alias qwen3.5-4b `
    --port 8080
```

Wait for:

```text
llama_server: model loaded
llama_server: listening on http://127.0.0.1:8080
```

Keep this PowerShell window open.

---

## 4. Check the API

Open a second PowerShell window.

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

Check the model:

```powershell
(Invoke-RestMethod `
    -Uri "http://127.0.0.1:8080/v1/models").data |
    Select-Object id
```

Expected model ID:

```text
qwen3.5-4b
```

---

## 5. Install ZeroClaw

Install the Windows x64 release of ZeroClaw.

Verify:

```powershell
zeroclaw --version
```

Record the installed version:

```text
ZeroClaw version: __________________
```

---

## 6. Configure llama.cpp as the model provider

Create the provider:

```powershell
zeroclaw config init providers.models.llamacpp.local
```

Set the endpoint:

```powershell
zeroclaw config set `
    providers.models.llamacpp.local.uri `
    "http://127.0.0.1:8080"
```

Set the model:

```powershell
zeroclaw config set `
    providers.models.llamacpp.local.model `
    "qwen3.5-4b"
```

Set the model as text-only:

```powershell
zeroclaw config set `
    providers.models.llamacpp.local.vision `
    false
```

Verify:

```powershell
zeroclaw config list `
    --filter providers.models.llamacpp.local
```

Confirm:

```text
uri    = http://127.0.0.1:8080
model  = qwen3.5-4b
vision = false
```

---

## 7. Create the agent

```powershell
zeroclaw agents create workshop
```

Create its risk profile:

```powershell
zeroclaw config init risk_profiles.workshop
```

Connect the agent to llama.cpp:

```powershell
zeroclaw config set `
    agents.workshop.model_provider `
    "llamacpp.local"
```

Assign the risk profile:

```powershell
zeroclaw config set `
    agents.workshop.risk_profile `
    "workshop"
```

Disable the precheck for this local validation:

```powershell
zeroclaw config set `
    agents.workshop.precheck.enabled `
    false
```

---

## 8. Expose only the required tools

The agent needs:

```text
file_read
glob_search
```

Create the configuration patch:

```powershell
$Patch = @'
[
  {
    "op": "replace",
    "path": "/risk_profiles/workshop/allowed_tools",
    "value": ["file_read", "glob_search"]
  }
]
'@
```

Save and apply it:

```powershell
$Patch | Set-Content "$HOME\zeroclaw-tools-patch.json"

zeroclaw config patch `
    "$HOME\zeroclaw-tools-patch.json"
```

Verify:

```powershell
zeroclaw config get `
    risk_profiles.workshop.allowed_tools
```

Expected:

```text
["file_read", "glob_search"]
```

---

## 9. Create the workspace

```powershell
New-Item `
    -ItemType Directory `
    -Path "$HOME\zeroclaw-workshop" `
    -Force
```

Create two files:

```powershell
"Intel AI-GPU Workshop validation successful." |
    Set-Content "$HOME\zeroclaw-workshop\validation.txt"

"Module 0 uses llama.cpp with SYCL and Level Zero." |
    Set-Content "$HOME\zeroclaw-workshop\hardware.txt"
```

Verify:

```powershell
Get-ChildItem "$HOME\zeroclaw-workshop"
```

Expected:

```text
hardware.txt
validation.txt
```

Assign the workspace:

```powershell
zeroclaw config set `
    agents.workshop.workspace.path `
    "$HOME\zeroclaw-workshop"
```

---

## 10. Test tool restraint

```powershell
zeroclaw agent `
    -a workshop `
    -m "What is 2 + 2? Answer directly without using a tool."
```

Expected:

```text
4
```

No tool should be invoked.

**Result:**

```text
PASS / FAIL
```

---

## 11. Test one tool

```powershell
zeroclaw agent `
    -a workshop `
    -m "Use the file_read tool to read validation.txt. Return only the exact file contents."
```

Expected:

```text
Intel AI-GPU Workshop validation successful.
```

**Result:**

```text
PASS / FAIL
```

---

## 12. Test a multi-step agent task

```powershell
zeroclaw agent `
    -a workshop `
    -m "Use glob_search to list the .txt files in your workspace. Then use file_read to read validation.txt and return its exact contents."
```

Expected behavior:

```text
glob_search
      ↓
hardware.txt
validation.txt
      ↓
file_read
      ↓
Intel AI-GPU Workshop validation successful.
```

**Result:**

```text
PASS / FAIL
```

---

## 13. Record the Panther Lake results

```text
Platform:
Panther Lake

Intel GPU:
________________________________

Intel graphics driver:
________________________________

llama.cpp build:
________________________________

ZeroClaw version:
________________________________

Model:
Qwen3.5-4B Q4_K_M

Context:
32768

llama-bench:

pp512: __________ t/s
tg128: __________ t/s

Agent validation:

Tool restraint:              PASS / FAIL
file_read:                   PASS / FAIL
glob_search → file_read:     PASS / FAIL
```

Also observe the `llama-server` window during each ZeroClaw task.

Useful measurements include:

```text
prompt eval tokens
prompt tokens/s
generation tokens/s
total time
```

---

## Validation target

The Panther Lake configuration is ready for Module 0.5 when:

```text
SYCL device detected             PASS
Level Zero detected              PASS
Qwen3.5-4B loads                 PASS
llama-server starts              PASS
ZeroClaw connects                PASS
Tool restraint works             PASS
file_read works                  PASS
glob_search → file_read works    PASS
Interactive latency acceptable   PASS
```

The resulting architecture is:

```text
User objective
      ↓
ZeroClaw
      ↓
Qwen3.5-4B
      ↓
Tool decision
      ↓
file_read / glob_search
      ↓
Model response
      ↓
llama-server
      ↓
SYCL / DPC++
      ↓
Level Zero
      ↓
Intel Graphics
```
