# Module 0: Run a Local LLM with SYCL on Intel Graphics

Run a lightweight language model directly on Intel graphics through the `llama.cpp` SYCL backend.

```text
Qwen2.5-0.5B-Instruct
          ↓
         GGUF
          ↓
      llama.cpp
          ↓
     SYCL / DPC++
          ↓
      Level Zero
          ↓
     Intel Graphics
```

## What you will do

- discover the Intel GPU through SYCL and Level Zero
- run a quantized language model on the Intel GPU
- observe interactive local inference
- measure prompt-processing and token-generation throughput

## Requirements

- Windows 11 x64
- supported Intel integrated or discrete graphics
- current Intel graphics driver
- PowerShell
- internet access for the initial downloads
- approximately 1 GB of free disk space

Exact GPU names, memory values, compute units, driver versions and performance results will vary by system.

---

## 1. Create the module workspace

Open PowerShell:

```powershell
cd "$HOME\Desktop"

New-Item `
    -ItemType Directory `
    -Path ".\module-0-sycl-local-inference" `
    -Force

cd ".\module-0-sycl-local-inference"

New-Item -ItemType Directory -Path ".\llama-sycl" -Force
New-Item -ItemType Directory -Path ".\models" -Force
```

The workspace will contain:

```text
module-0-sycl-local-inference/
├── llama-sycl/
├── models/
```

---

## 2. Download llama.cpp for SYCL

You can open the official [llama.cpp releases page](https://github.com/ggml-org/llama.cpp/releases) and find the latest SYCL for Windows x64.<br>
At the time of the training, we have validated release b11873.<br>
You can directly download it here [llama-b11873-bin-win-sycl-x64.zip](https://github.com/ggml-org/llama.cpp/releases/download/b11873/llama-b11873-bin-win-sycl-x64.zip) 

Extract the complete archive into:

```text
module-0-sycl-local-inference\llama-sycl
```

Keep the supplied DLL files together with the executables.

Return to the module directory:

```powershell
cd "$HOME\Desktop\module-0-sycl-local-inference"
```

Check the installed build:

```powershell
.\llama-sycl\llama-cli.exe --version
```

List the available devices:

```powershell
.\llama-sycl\llama-cli.exe --list-devices
```

Look for an Intel device similar to:

```text
SYCL0: Intel(R) Graphics
```

The exact device name and reported memory will differ by system.

---

## 3. Inspect the Intel software path

Run:

```powershell
.\llama-sycl\llama-bench.exe --list-devices
```

Look for these indicators:

```text
GGML_SYCL_DNNL: yes
GGML_SYCL_SUPPORT_LEVEL_ZERO_API: yes
GGML_SYCL_USE_LEVEL_ZERO_API: 1
[level_zero:gpu:0]
load_backend: loaded SYCL backend
```

The output shows the path used by `llama.cpp`:

```text
llama.cpp
    ↓
ggml-sycl
    ↓
SYCL / DPC++
    ↓
Level Zero
    ↓
Intel graphics driver
    ↓
Intel GPU
```

---

## 4. Install the Hugging Face CLI

Install the Hugging Face CLI:

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://hf.co/cli/install.ps1 | iex"
```

If `hf` is not immediately recognized, close PowerShell and open a new PowerShell window.

Return to the module directory:

```powershell
cd "$HOME\Desktop\module-0-sycl-local-inference"
```

Verify the installation:

```powershell
hf --help
```

---

## 5. Download the model

Download the Qwen2.5-0.5B-Instruct Q4_K_M GGUF:

```powershell
hf download `
    lmstudio-community/Qwen2.5-0.5B-Instruct-GGUF `
    Qwen2.5-0.5B-Instruct-Q4_K_M.gguf `
    --local-dir ".\models"
```

Verify the file:

```powershell
Get-Item ".\models\Qwen2.5-0.5B-Instruct-Q4_K_M.gguf" |
    Select-Object Name, Length, FullName
```

Set the model path:

```powershell
$Model = Resolve-Path `
    ".\models\Qwen2.5-0.5B-Instruct-Q4_K_M.gguf"
```

---

## 6. Run local inference

Open Windows Task Manager and select:

```text
Performance → GPU
```

Keep Task Manager visible while running the model.

From the module directory, run:

```powershell
.\llama-sycl\llama-cli.exe `
    -m $Model `
    -ngl 99 `
    -p "Hello"
```

`-ngl 99` requests that the model layers be offloaded to the GPU.

When the interactive prompt appears, try:

```text
Hello
```

Then:

```text
What is your name?
```

Observe:

- the model response in PowerShell
- prompt-processing throughput
- generation throughput
- Intel GPU activity in Task Manager

Enter `/exit` or press `Ctrl+C` when finished.

---

## 7. Run the benchmark

Run:

```powershell
.\llama-sycl\llama-bench.exe `
    -m $Model `
    -ngl 99
```

Find these two tests in the results:

```text
pp512
tg128
```

Record your results:

```text
Intel GPU:
________________________________________

Driver:
________________________________________

llama.cpp build:
________________________________________

Model:
Qwen2.5-0.5B-Instruct-Q4_K_M

Backend:
SYCL

pp512:
________________ t/s

tg128:
________________ t/s
```

- `pp512` measures the benchmark's prompt-processing workload.
- `tg128` measures the benchmark's token-generation workload.

There is no required performance score. Results vary with the GPU, driver, memory configuration, thermal conditions and `llama.cpp` build.

---

## Completion check

Module 0 is complete when:

- `llama-cli --list-devices` reports an Intel SYCL device
- `llama-bench --list-devices` shows a Level Zero GPU
- the SYCL backend loads
- the GGUF model generates a local response
- Intel GPU activity is visible
- `llama-bench` produces `pp512` and `tg128` results

You have now run a real LLM through:

```text
User
  ↓
llama.cpp
  ↓
SYCL / DPC++
  ↓
Level Zero
  ↓
Intel GPU
  ↓
Local response
```
