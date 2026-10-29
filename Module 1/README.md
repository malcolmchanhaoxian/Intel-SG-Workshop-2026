# Module 1: Serving LLMs on Intel GPUs with vLLM

<img width="1885" height="544" alt="image" src="https://github.com/user-attachments/assets/943a3f10-181c-4b2b-9302-53a2e62ad307" />

## From Local Inference to a Model Serving Engine

In the previous module, we explored local AI inference and connected an agent to a locally running model.

In this module, we move the model behind a **model serving engine**.

Instead of interacting directly with the model runtime, applications communicate with an **OpenAI-compatible API** exposed by vLLM.

The architecture becomes:

```text
Application or Agent
        |
        v
OpenAI-Compatible API
        |
        v
      vLLM
        |
        v
 Intel Arc Pro GPUs
        |
        v
Qwen3.8-27B-FP8
```

We will use Intel's `llm-scaler-vllm` container and Intel Arc Pro GPUs.

During this module, we will compare:

```text
TP=1
1 GPU
```

against:

```text
TP=2
2 GPUs using Tensor Parallelism
```

Rather than looking only at single-request token generation, we will increase request concurrency and observe how the serving engine behaves under load.

---

# Learning Objectives

By the end of this module, you will be able to:

- Validate Intel GPU PCIe detection
- Validate the Linux `xe` kernel driver
- Validate `/dev/dri` GPU device nodes
- Use `xpu-smi` to inspect Intel GPUs
- Validate GPU access from Docker
- Start Intel's `llm-scaler-vllm` container
- Validate PyTorch XPU inside the container
- Serve a 27B FP8 model with vLLM
- Access the OpenAI-compatible API
- Understand Tensor Parallelism
- Compare TP=1 and TP=2 inference
- Benchmark an OpenAI-compatible endpoint using llama-benchy
- Measure end-to-end Time to First Token
- Capture GPU power and memory telemetry using XPU-SMI
- Identify inference saturation under concurrent requests
- Generate a consolidated TP=1 versus TP=2 comparison report
- Connect an agent such as Hermes to the vLLM API

---

# Lab Environment

The validated environment used during development of this module was:

```text
Operating System:
Ubuntu 24.04 LTS

Kernel:
6.17.0-1009-intel

GPU:
2 x Intel Arc Pro B70

GPU Driver:
xe

Container:
intel/llm-scaler-vllm:1.5

Model:
Qwen/Qwen3.8-27B-FP8

Serving Engine:
vLLM

Benchmark:
llama-benchy
```

Your exact GPU count, PCI addresses, storage layout, or available GPU memory may differ.

---

# Part 1: Validate the Intel GPUs

Before starting Docker or vLLM, validate the hardware from the Linux host.

## 1.1 Check PCIe Devices

Run:

```bash
lspci | grep -Ei 'vga|display'
```

Example:

```text
05:00.0 VGA compatible controller: ASPEED Technology, Inc. ASPEED Graphics Family
18:00.0 VGA compatible controller: Intel Corporation Device e223
54:00.0 VGA compatible controller: Intel Corporation Device e223
```

On the validated development system:

```text
18:00.0
54:00.0
```

were the two Intel Arc Pro B70 GPUs.

Record the PCI addresses of the Intel GPUs. You will use them when checking the kernel driver.

---

## 1.2 Check the Kernel Driver

Check each Intel GPU using its PCI address.

Example:

```bash
lspci -k -s 18:00.0
```

```bash
lspci -k -s 54:00.0
```

Expected output includes:

```text
Kernel driver in use: xe
Kernel modules: xe
```

For example:

```text
18:00.0 VGA compatible controller: Intel Corporation Device e223
        Subsystem: Intel Corporation Device 1701
        Kernel driver in use: xe
        Kernel modules: xe
```

### If the `xe` Driver Is Not Detected

If an Intel GPU is visible with `lspci` but the following line is missing:

```text
Kernel driver in use: xe
```

**stop here**.

Do not continue to Docker or vLLM until the GPU driver is working.

Go to:

[**Intel Kernel Battlemage.md**](Intel%20Kernel%20Battlemage.md)

That guide covers the additional Intel kernel and Battlemage driver installation steps required for systems where the operating system does not automatically detect and bind the GPU to the `xe` driver.

After completing that guide, return here and run:

```bash
lspci -k -s 18:00.0
lspci -k -s 54:00.0
```

Continue only when every Intel GPU reports:

```text
Kernel driver in use: xe
```

---

# Part 2: Validate the DRM Devices

The Intel GPU driver exposes devices through the Linux Direct Rendering Manager.

Run:

```bash
ls -l /dev/dri
```

On a two-GPU system with a separate management display adapter, you may see:

```text
card0
card1
card2
renderD128
renderD129
```

The render devices are particularly important:

```text
renderD128
renderD129
```

These are the GPU compute device nodes that will be exposed to Docker.

## 2.1 Check the PCI-to-DRM Mapping

Run:

```bash
ls -l /dev/dri/by-path
```

Example:

```text
pci-0000:05:00.0-card   -> ../card0

pci-0000:18:00.0-card   -> ../card1
pci-0000:18:00.0-render -> ../renderD128

pci-0000:54:00.0-card   -> ../card2
pci-0000:54:00.0-render -> ../renderD129
```

In this example:

```text
18:00.0 -> renderD128
54:00.0 -> renderD129
```

The `/dev/dri/by-path` mapping is also needed by the oneCCL communication stack used by vLLM.

---

# Part 3: Validate XPU-SMI

Run:

```bash
xpu-smi discovery
```

You should see all Intel GPUs.

Example:

```text
Device 0
Device Name: Intel(R) Arc(TM) Pro B70 Graphics
Device State: normal
PCI BDF Address: 0000:18:00.0

Device 1
Device Name: Intel(R) Arc(TM) Pro B70 Graphics
Device State: normal
PCI BDF Address: 0000:54:00.0
```

For a more readable system overview, run:

```bash
xpu-smi
```

The dashboard displays information such as:

- GPU model
- PCI address
- device state
- power usage
- power limit
- GPU memory usage
- GPU compute mode
- running GPU processes

---

## 3.1 Fix Non-Root GPU Access

If this works:

```bash
sudo xpu-smi discovery
```

but this fails:

```bash
xpu-smi discovery
```

check the current user's groups:

```bash
groups
```

The user should have access to:

```text
video
render
```

Add the current user to both groups if required:

```bash
sudo usermod -aG render,video $USER
```

Log out and reconnect through SSH.

Verify:

```bash
groups
```

Then repeat:

```bash
xpu-smi discovery
```

The command should now work without `sudo`.

---

# Part 4: Validate Docker

Check the Docker client:

```bash
docker --version
```

Check the Docker server:

```bash
docker info --format 'Server Version: {{.ServerVersion}}'
```

Validate that Docker can access the DRM devices:

```bash
docker run --rm \
  --device=/dev/dri \
  ubuntu:24.04 \
  ls -l /dev/dri
```

The container should see the Intel GPU render nodes.

Example:

```text
card0
card1
card2
renderD128
renderD129
```

This confirms that Docker can receive the GPU devices from the host.

---

# Part 5: Pull Intel llm-scaler

Pull the validated workshop image:

```bash
docker pull intel/llm-scaler-vllm:1.5
```

Verify:

```bash
docker images intel/llm-scaler-vllm
```

Expected:

```text
intel/llm-scaler-vllm:1.5
```

The image includes the Intel XPU software environment required to run vLLM on the Intel GPUs.

---

# Part 6: Prepare the Model

Create the model directory:

```bash
mkdir -p ~/LLM
```

For this module, we use:

```text
Qwen/Qwen3.8-27B-FP8
```

The downloaded model occupies approximately:

```text
29 GB
```

Before downloading, check the available storage:

```bash
df -h ~/LLM
```

Ensure that the model can be downloaded without filling the host filesystem.

---

## 6.1 Install the Hugging Face CLI

Ubuntu 24.04 protects the system Python environment using PEP 668.

Do not bypass this protection using:

```text
--break-system-packages
```

Instead, create a dedicated virtual environment.

Install the Python virtual-environment package:

```bash
sudo apt install -y python3-venv
```

Create the environment:

```bash
python3 -m venv ~/hf-cli
```

Activate it:

```bash
source ~/hf-cli/bin/activate
```

Install the Hugging Face Hub client:

```bash
pip install -U huggingface_hub
```

Verify:

```bash
hf --version
```

Download the model directly into the workshop model directory:

```bash
hf download Qwen/Qwen3.8-27B-FP8 \
  --local-dir ~/LLM/Qwen3.8-27B-FP8
```

Check the resulting model size:

```bash
du -sh ~/LLM/Qwen3.8-27B-FP8
```

Check the remaining storage:

```bash
df -h /
```

Deactivate the virtual environment when finished:

```bash
deactivate
```

---

# Part 7: Start the llm-scaler Container

Expose both Intel GPUs to one persistent container.

TP=1 and TP=2 will then be controlled from inside the same container.

Run:

```bash
docker run --rm -it \
  --device=/dev/dri \
  -v /dev/dri/by-path:/dev/dri/by-path \
  --ipc=host \
  --network=host \
  -v ~/LLM:/llm/models \
  --entrypoint /bin/bash \
  intel/llm-scaler-vllm:1.5
```

The important options are:

```text
--device=/dev/dri
```

Exposes the GPU device nodes.

```text
-v /dev/dri/by-path:/dev/dri/by-path
```

Exposes the PCI-to-DRM mapping required by the oneCCL device communication path.

```text
--ipc=host
```

Allows the serving processes to use the host IPC namespace.

```text
--network=host
```

Exposes the vLLM API directly through the host network.

```text
-v ~/LLM:/llm/models
```

Makes the downloaded model available inside the container.

---

## 7.1 Verify the DRM Devices Inside the Container

Inside the container:

```bash
ls -l /dev/dri
```

Then:

```bash
ls -l /dev/dri/by-path
```

Confirm that both Intel GPU render devices and their PCI mappings are present.

---

# Part 8: Validate PyTorch XPU

Inside the container, run:

```bash
python -c "import torch; print('XPU available:', torch.xpu.is_available()); print('Visible XPU count:', torch.xpu.device_count())"
```

With both GPUs visible, the expected result is:

```text
XPU available: True
Visible XPU count: 2
```

At this point, the complete GPU software path has been validated:

```text
Intel Arc Pro GPU
        |
        v
Linux xe Driver
        |
        v
/dev/dri
        |
        v
Docker
        |
        v
llm-scaler
        |
        v
PyTorch XPU
        |
        v
vLLM
```

---

# Part 9: TP=1 - Serve on One GPU

The container can see both Intel GPUs.

For the TP=1 experiment, limit the application to device 0:

```bash
export ZE_AFFINITY_MASK=0
```

Validate the visible GPU count:

```bash
python -c "import torch; print('Visible XPUs:', torch.xpu.device_count())"
```

Expected:

```text
Visible XPUs: 1
```

Set the vLLM worker multiprocessing mode:

```bash
export VLLM_WORKER_MULTIPROC_METHOD=spawn
```

Start vLLM:

```bash
vllm serve /llm/models/Qwen3.8-27B-FP8 \
  --served-model-name Qwen3.8-27B \
  --dtype auto \
  --enforce-eager \
  --host 0.0.0.0 \
  --port 8001 \
  --trust-remote-code \
  --disable-sliding-window \
  --gpu-memory-utilization 0.95 \
  --max-model-len 4096 \
  --max-num-batched-tokens 2048 \
  --enable-prefix-caching \
  --block-size 64 \
  --quantization fp8 \
  --tensor-parallel-size 1 \
  --limit-mm-per-prompt '{"image":0,"video":0}'
```

Wait until the API server reports that startup has completed.

---

# Part 10: Discover the OpenAI-Compatible API

Open another SSH terminal to the host.

Query the model endpoint:

```bash
curl -s http://localhost:8001/v1/models \
  | python3 -m json.tool
```

You should see:

```text
Qwen3.8-27B
```

The API base URL is:

```text
http://localhost:8001/v1
```

The served model name is:

```text
Qwen3.8-27B
```

Applications use the served model name rather than the model's internal filesystem path.

---

# Part 11: Test Chat Completions

Send a request to the OpenAI-compatible Chat Completions API:

```bash
curl -s http://localhost:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3.8-27B",
    "messages": [
      {
        "role": "user",
        "content": "Explain tensor parallel inference in five concise bullet points."
      }
    ],
    "temperature": 0,
    "max_tokens": 512,
    "stream": false
  }' \
  | python3 -m json.tool
```

If a generated assistant response is returned, the serving path is working:

```text
Client
   |
   v
/v1/chat/completions
   |
   v
vLLM
   |
   v
Intel GPU
   |
   v
Qwen3.8-27B
```

A single request proves that the API works.

It does not provide a repeatable performance comparison.

For that, we will use llama-benchy.

---

# Part 12: Why llama-benchy?

For this exercise, we use **llama-benchy**, a lightweight benchmarking tool for OpenAI-compatible LLM endpoints.

It provides a practical way to compare TP=1 and TP=2 without installing a large load-testing framework.

More importantly, llama-benchy measures the behavior experienced through the serving API.

## 12.1 It Benchmarks the Real API Path

llama-benchy sends requests through:

```text
/v1/chat/completions
```

This is the same interface used by an application or agent:

```text
Client
   |
   v
OpenAI-Compatible API
   |
   v
vLLM
   |
   v
Intel GPU
```

The test therefore includes the model serving layer rather than calling the inference engine directly.

---

## 12.2 It Provides Controlled and Repeatable Workloads

llama-benchy allows us to control:

```text
Prompt-processing tokens
Generation tokens
Number of runs
Warmup runs
Concurrency
```

For this module, the benchmark uses:

```text
Prompt Processing: 512 tokens
Generation:        128 tokens
Measured Runs:     5
Warmup Runs:       1
Concurrency:       1, 4, 16
```

The option:

```bash
--exact-tg
```

forces the output length to match the requested generation length.

This avoids comparing requests that stop after different numbers of output tokens.

TP=1 and TP=2 therefore receive the same benchmark workload.

---

## 12.3 It Measures True End-to-End TTFT

Time to First Token matters for interactive AI applications because it represents how long a user waits before generated output begins to arrive.

Some benchmark methods treat the first response chunk as the first token.

However, an HTTP response chunk may contain protocol information without containing usable generated text.

llama-benchy distinguishes between:

```text
Time to First Response
```

and:

```text
End-to-End Time to First Token
```

For this workshop, use:

```bash
--latency-mode generation
```

This mode uses token generation probes to estimate serving overhead and reports:

```text
TTFR
Estimated Prompt Processing Time
End-to-End TTFT
```

This gives a more meaningful representation of user-perceived responsiveness when comparing TP=1 and TP=2.

---

## 12.4 What We Will Measure

The benchmark focuses on four areas:

```text
Prompt Processing Throughput
        |
        +--> How quickly can the server process input?

Token Generation Throughput
        |
        +--> How quickly can the server generate output?

Time to First Token
        |
        +--> How quickly does generated output begin?

Concurrency
        |
        +--> How does serving behavior change as load increases?
```

These application-level measurements are combined with XPU-SMI telemetry:

```text
llama-benchy
     |
     +-- PP tok/s
     +-- TG tok/s
     +-- TG tok/s per request
     +-- TTFT
     |
     +-------------------+
                         |
                         v
                  Comparison Report
                         ^
                         |
     +-------------------+
     |
XPU-SMI
     |
     +-- GPU power
     +-- GPU memory
     +-- GPU frequency
```

This allows us to evaluate not only whether TP=2 is faster, but also where additional GPUs improve serving capacity and where the system begins to saturate.

---

# Part 13: Install llama-benchy

Create a dedicated virtual environment:

```bash
python3 -m venv ~/llama-benchy-env
```

Activate it:

```bash
source ~/llama-benchy-env/bin/activate
```

Clone the repository:

```bash
cd ~
git clone https://github.com/eugr/llama-benchy.git
cd llama-benchy
```

Install llama-benchy into the virtual environment:

```bash
pip install -e .
```

Verify the executable:

```bash
which llama-benchy
```

Expected:

```text
/home/intel/llama-benchy-env/bin/llama-benchy
```

Check the command:

```bash
llama-benchy --help | head
```

---

# Part 14: Benchmark TP=1

Create the TP=1 result directory:

```bash
mkdir -p ~/llm-server/results/tp1
```

## 14.1 Start XPU-SMI Telemetry

Open another SSH terminal and start the GPU 0 telemetry capture:

```bash
xpu-smi dump \
  --device=0 \
  --metrics=0,1,2,3,5,17,18,19,20,31 \
  --file ~/llm-server/results/tp1/xpu-concurrency-tp1-gpu0.csv
```

Leave XPU-SMI running throughout the benchmark.

## 14.2 Run llama-benchy

In another terminal:

```bash
source ~/llama-benchy-env/bin/activate
cd ~/llama-benchy
```

Run:

```bash
llama-benchy \
  --base-url http://localhost:8001/v1 \
  --model /home/intel/LLM/Qwen3.8-27B-FP8 \
  --served-model-name Qwen3.8-27B \
  --tokenizer /home/intel/LLM/Qwen3.8-27B-FP8 \
  --pp 512 \
  --tg 128 \
  --exact-tg \
  --runs 5 \
  --warmup-runs 1 \
  --concurrency 1 4 16 \
  --latency-mode generation \
  --no-cache \
  --save-result ~/llm-server/results/tp1/bench-concurrency-tp1.csv \
  --format csv
```

When the benchmark completes, stop the telemetry capture using:

```text
q
```

or:

```text
Ctrl+C
```

---

# Part 15: Understand Saturation

Watch the vLLM server console during the benchmark.

Under high concurrency, the server may report a state similar to:

```text
Running: 4 reqs
Waiting: 60 reqs
GPU KV cache usage: 94.1%
```

This illustrates an important distinction:

```text
Client Concurrency
        |
        v
Request Queue
        |
        v
vLLM Scheduler
        |
        v
Running Requests
        |
        v
GPU and KV Cache
```

Sending more concurrent requests does not guarantee higher throughput.

Once the inference engine reaches its useful serving capacity, additional requests increasingly wait in the queue.

A saturation point is indicated when:

- total throughput stops increasing materially
- per-request throughput declines
- TTFT increases sharply
- more requests remain queued
- GPU power has already approached its workload plateau

The purpose of the concurrency sweep is to observe this behavior rather than assume where saturation occurs.

---

# Part 16: Switch to TP=2

Return to the container running the TP=1 vLLM server.

Stop vLLM:

```text
Ctrl+C
```

Remain inside the same Docker container.

Remove the GPU affinity restriction:

```bash
unset ZE_AFFINITY_MASK
```

Verify that both GPUs are visible:

```bash
python -c "import torch; print('Visible XPUs:', torch.xpu.device_count())"
```

Expected:

```text
Visible XPUs: 2
```

Start vLLM with Tensor Parallelism set to 2:

```bash
vllm serve /llm/models/Qwen3.8-27B-FP8 \
  --served-model-name Qwen3.8-27B \
  --dtype auto \
  --enforce-eager \
  --host 0.0.0.0 \
  --port 8001 \
  --trust-remote-code \
  --disable-sliding-window \
  --gpu-memory-utilization 0.95 \
  --max-model-len 4096 \
  --max-num-batched-tokens 2048 \
  --enable-prefix-caching \
  --block-size 64 \
  --quantization fp8 \
  --tensor-parallel-size 2 \
  --limit-mm-per-prompt '{"image":0,"video":0}'
```

The application-facing API remains:

```text
http://localhost:8001/v1
```

Only the underlying compute topology has changed.

---

# Part 17: Benchmark TP=2

Create the TP=2 result directory:

```bash
mkdir -p ~/llm-server/results/tp2
```

## 17.1 Capture GPU 0

In a separate SSH terminal:

```bash
xpu-smi dump \
  --device=0 \
  --metrics=0,1,2,3,5,17,18,19,20,31 \
  --file ~/llm-server/results/tp2/xpu-concurrency-tp2-gpu0.csv
```

## 17.2 Capture GPU 1

In another SSH terminal:

```bash
xpu-smi dump \
  --device=1 \
  --metrics=0,1,2,3,5,17,18,19,20,31 \
  --file ~/llm-server/results/tp2/xpu-concurrency-tp2-gpu1.csv
```

Leave both telemetry captures running.

## 17.3 Run the Same Benchmark

Activate llama-benchy:

```bash
source ~/llama-benchy-env/bin/activate
cd ~/llama-benchy
```

Run:

```bash
llama-benchy \
  --base-url http://localhost:8001/v1 \
  --model /home/intel/LLM/Qwen3.8-27B-FP8 \
  --served-model-name Qwen3.8-27B \
  --tokenizer /home/intel/LLM/Qwen3.8-27B-FP8 \
  --pp 512 \
  --tg 128 \
  --exact-tg \
  --runs 5 \
  --warmup-runs 1 \
  --concurrency 1 4 16 \
  --latency-mode generation \
  --no-cache \
  --save-result ~/llm-server/results/tp2/bench-concurrency-tp2.csv \
  --format csv
```

Stop both XPU-SMI captures when the benchmark completes.

---

# Part 18: Understand the Metrics

## 18.1 Prompt Processing

```text
PP tok/s
```

Prompt-processing throughput measures how quickly the server processes input tokens.

This phase is commonly called:

```text
prefill
```

Higher prompt-processing throughput is particularly useful for requests containing:

- long user prompts
- large system prompts
- retrieved documents
- long conversation history
- agent context

---

## 18.2 Token Generation

```text
TG tok/s
```

Token-generation throughput measures how quickly the server generates output tokens.

At concurrency greater than 1, distinguish between:

```text
Total TG tok/s
```

and:

```text
TG tok/s per request
```

Total throughput represents the overall capacity of the serving system.

Per-request throughput represents the generation performance experienced by an individual request.

---

## 18.3 Time to First Token

```text
TTFT
```

TTFT is important for interactive applications because it measures how long the user waits before usable generated output begins.

Higher concurrency may increase total throughput while also increasing TTFT.

A configuration that delivers the highest total throughput may not provide the best interactive user experience.

---

# Part 19: Generate the Comparison Report

The workshop includes:

```text
compare-results.sh
```

Copy the script into:

```text
~/llm-server/compare-results.sh
```

Make it executable:

```bash
chmod +x ~/llm-server/compare-results.sh
```

The required directory structure is:

```text
~/llm-server/results/
|
+-- tp1/
|   +-- bench-concurrency-tp1.csv
|   +-- xpu-concurrency-tp1-gpu0.csv
|
+-- tp2/
    +-- bench-concurrency-tp2.csv
    +-- xpu-concurrency-tp2-gpu0.csv
    +-- xpu-concurrency-tp2-gpu1.csv
```

Run:

```bash
~/llm-server/compare-results.sh
```

The script combines:

```text
llama-benchy
     +-- Generation throughput
     +-- Per-request generation throughput
     +-- TTFT

XPU-SMI
     |
     +-- GPU power
     +-- GPU memory
     +-- GPU frequency

              |
              v

TP=1 versus TP=2 Report
```

The script displays a bordered comparison dashboard directly in the SSH terminal.

It also generates:

```text
~/llm-server/results/comparison.csv
```

and:

```text
~/llm-server/results/comparison.md
```

Values reported as `N/A` by XPU-SMI remain `N/A`.

They are never interpreted as zero.

---

# Part 20: Interpret Scaling

The objective is not to prove:

```text
2 GPUs = 2x performance
```

Tensor Parallelism can affect different phases of inference differently.

At low concurrency:

- single-request decode improvement may be modest
- prompt processing may improve substantially
- TTFT may improve
- the second GPU introduces communication and synchronization

At higher concurrency:

- TP=1 may reach a throughput plateau
- additional requests may wait in the scheduler queue
- TTFT may rise sharply
- TP=2 may continue increasing total serving throughput
- the second GPU may provide significantly more serving headroom

The results may therefore resemble:

```text
TP=1
C1 -> C4 -> C16
      |
      +--> Throughput reaches a plateau
           while TTFT continues increasing

TP=2
C1 -> C4 -> C16
             |
             +--> Throughput still increasing
                  at the highest concurrency tested
```

If TP=2 is still scaling at the highest tested concurrency, do not describe that concurrency as the TP=2 saturation point.

Instead report:

```text
TP=2 saturation was not reached within the tested range.
```

The exact scaling behavior depends on:

- model architecture
- model precision
- GPU memory
- GPU count
- prompt length
- output length
- KV-cache requirements
- request concurrency
- vLLM scheduler configuration
- inter-GPU communication overhead

The purpose of the exercise is to measure this behavior rather than assume the scaling factor.

---

# Part 21: Connect Hermes

We now have an OpenAI-compatible model service.

The important parameters are:

```text
Base URL:
http://GPU_SERVER_IP:8001/v1

Model:
Qwen3.8-27B
```

If Hermes runs directly on the GPU server, use:

```text
http://localhost:8001/v1
```

If Hermes runs on another machine, replace `localhost` with the reachable IP address of the vLLM server.

Before configuring Hermes, test connectivity from the machine running Hermes:

```bash
curl http://GPU_SERVER_IP:8001/v1/models
```

The response should contain:

```text
Qwen3.8-27B
```

Configure Hermes with:

```text
Provider:
OpenAI-compatible

Base URL:
http://GPU_SERVER_IP:8001/v1

Model:
Qwen3.8-27B
```

If the Hermes configuration requires an API-key field but the vLLM server was started without authentication, use the value required by the Hermes client configuration.

The architecture is:

```text
Hermes
   |
   | OpenAI-compatible request
   v
vLLM API
   |
   | Request scheduling
   v
Intel Arc Pro GPU
   |
   v
Qwen3.8-27B-FP8
```

Hermes does not need to know:

- where the model files are stored
- which GPU executes the model
- whether TP=1 or TP=2 is used
- how vLLM manages request scheduling
- how model memory is allocated

Hermes interacts with the API.

vLLM manages the serving and compute infrastructure.

---

# Module 1 Checkpoint

## Host

- [ ] Intel GPUs are visible through PCIe
- [ ] `xe` kernel driver is loaded
- [ ] `/dev/dri/renderD*` devices are present
- [ ] `/dev/dri/by-path` contains the Intel GPU mappings
- [ ] User has `video` and `render` permissions
- [ ] `xpu-smi discovery` works
- [ ] `xpu-smi` reports the expected GPUs

## Docker

- [ ] Docker is operational
- [ ] `/dev/dri` is visible inside Docker
- [ ] `/dev/dri/by-path` is mounted inside the container
- [ ] `intel/llm-scaler-vllm:1.5` is installed
- [ ] `torch.xpu.is_available()` returns `True`
- [ ] Both GPUs can be detected inside the container

## vLLM

- [ ] Qwen3.8-27B-FP8 loads successfully
- [ ] TP=1 serving works
- [ ] TP=2 serving works
- [ ] `/v1/models` responds
- [ ] `/v1/chat/completions` responds
- [ ] OpenAI-compatible endpoint is accessible

## Benchmark

- [ ] llama-benchy is installed
- [ ] TP=1 benchmark is captured
- [ ] TP=2 benchmark is captured
- [ ] XPU-SMI telemetry is captured
- [ ] `compare-results.sh` executes successfully
- [ ] `comparison.csv` is generated
- [ ] `comparison.md` is generated
- [ ] TP=1 saturation behavior is understood
- [ ] TP=2 scaling headroom is understood

## Agent

- [ ] Hermes can reach the vLLM endpoint
- [ ] Hermes uses `Qwen3.8-27B`
- [ ] A prompt successfully travels from Hermes to vLLM

---

# What We Built

At the beginning of this module:

```text
Application
   |
   v
Local Model
```

At the end:

```text
               OpenAI-Compatible API
                        |
                        v
Hermes -------------> vLLM
                        |
                 Request Scheduler
                        |
              +---------+---------+
              |                   |
              v                   v
          Intel GPU 0         Intel GPU 1
              \                   /
               +--------+--------+
                        |
                        v
                Qwen3.8-27B-FP8
```

We separated:

```text
Agent Layer
    |
Serving Layer
    |
Compute Layer
```

This separation allows the client or agent to continue using the same API while the infrastructure underneath changes from TP=1 to TP=2.

It also establishes the foundation for later workshop modules involving:

- multi-model serving
- semantic routing
- heterogeneous inference
- agentic AI
- larger serving topologies
