# HomeAssistant Voice Control Recipes

GPU/CUDA-accelerated voice control stack for Home Assistant. Runs on **x86/x64** and **ARM64** (including the [NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/)).

## 100% Local — No Cloud, No Subscriptions, No Data Leaving Your Network

Every component in this stack runs **entirely on your own hardware**. Your voice commands, transcriptions, conversations, and responses never leave your local network — no cloud APIs, no third-party services, no internet connection required after initial setup.

This means:
- **Privacy** — No audio or text is sent to external servers. Your voice data stays on your machine.
- **Reliability** — No dependency on cloud uptime, API rate limits, or vendor availability. Your voice control works even if your internet goes down.
- **Speed** — No round-trip latency to remote servers. With GPU acceleration, the entire pipeline (wake word → STT → LLM → TTS) responds in under a second.
- **No recurring costs** — No API usage fees, no monthly subscriptions. Once deployed, it runs for free.
- **Full control** — You choose the models, tune the parameters, and own the entire stack. Swap models, adjust thresholds, or customize voices without asking anyone's permission.

## Architecture Overview

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  Wake Word   │───>│ Speech-to-   │───>│   LLM        │───>│ Text-to-     │
│  Detection   │    │ Text (STT)   │    │   Agent      │    │ Speech (TTS) │
│              │    │              │    │              │    │              │
│ OpenWakeWord │    │ ONNX ASR +   │    │ Qwen3-14B    │    │ Kokoro       │
│              │    │ Voice Match  │    │ (llama.cpp)  │    │ FastAPI      │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
     :10400              :10300              :8080              :8880
                         :10350                                :10900
```

Every component runs as a Docker container with NVIDIA GPU passthrough, communicating via the [Wyoming protocol](https://github.com/rhasspy/wyoming) — Home Assistant's native voice satellite interface.

---

## Components

### 1. Wake Word Detection — OpenWakeWord

**Directory:** [`wake-word/`](wake-word/)

Listens for a wake word to activate the voice pipeline. Uses the `okay_nabu` model by default, with support for custom wake word models.

| Setting | Value |
|---------|-------|
| Image | `rhasspy/wyoming-openwakeword:latest` |
| Port | `10400` (TCP + UDP) |
| Wake Word | `okay_nabu` |
| Threshold | `0.65` |
| Trigger Level | `3` |

**Custom models** can be placed in `/opt/models/wyoming-openwakeword/custom` and will be available in the `/custom` directory inside the container.

```bash
docker compose -f wake-word/compose.openwakeword.yml up -d
```

---

### 2. Speech-to-Text (STT) — Wyoming ONNX ASR

**Directory:** [`speech-to-text/`](speech-to-text/)

Converts speech audio into text using GPU-accelerated ONNX models. The recommended model is **NVIDIA NeMo Parakeet TDT 0.6B v2** — a fast, accurate ASR model optimized for streaming speech recognition.

| Setting | Value |
|---------|-------|
| Image | `ghcr.io/jxlarrea/wyoming-onnx-asr-gpu` |
| Port | `10300` |
| Model | `nemo-parakeet-tdt-0.6b-v2` |

Alternative models (commented out in the compose file):
- `onnx-community/whisper-large-v3-turbo`
- `mekpro/whisper-medium-turbo`

```bash
docker compose -f speech-to-text/compose.wyoming-onnx-asr.yaml up -d
```

#### Speaker Verification — Wyoming Voice Match

An optional layer that sits between the ASR service and Home Assistant, verifying the speaker's identity before processing commands. This prevents unauthorized users from controlling your smart home via voice.

| Setting | Value |
|---------|-------|
| Image | `ghcr.io/jxlarrea/wyoming-voice-match:latest` |
| Port | `10350` |
| Upstream | `tcp://<ASR_HOST>:10300` |
| Verify Threshold | `0.26` |
| Extraction Threshold | `0.25` |
| Require Speaker Match | `true` |

Voice Match connects upstream to the ONNX ASR service. When `REQUIRE_SPEAKER_MATCH=true`, only enrolled speakers can execute commands. Update `UPSTREAM_URI` to point to your ASR instance.

```bash
docker compose -f speech-to-text/compose.wyioming-voice-match.yml up -d
```

---

### 3. Conversational Agent (LLM) — Qwen3 via llama.cpp

**Directory:** [`conversational-agent-llm/`](conversational-agent-llm/)

The brain of the pipeline. Runs **Qwen3-14B** (Q8_0 quantization) with **speculative decoding** using a Qwen3-0.6B draft model for significantly faster inference. Served via [llama.cpp](https://github.com/ggml-org/llama.cpp) with an OpenAI-compatible API.

#### Key Configuration

| Parameter | Value | Purpose |
|-----------|-------|---------|
| Main Model | `Qwen3-14B-Q8_0.gguf` | Primary inference model |
| Draft Model | `Qwen3-0.6B-Q4_K_M.gguf` | Speculative decoding for faster generation |
| Context Window | `24576` tokens | Sufficient for complex multi-turn conversations |
| GPU Layers | `999` | Offload all layers to GPU |
| Temperature | `0.0` | Deterministic output for reliable smart home control |
| Flash Attention | `on` | Faster attention computation |
| KV Cache Quantization | `Q8_0` | Reduced VRAM usage |
| Thinking Mode | `disabled` | Skips chain-of-thought for lower latency |

#### Speculative Decoding

The draft model (`Qwen3-0.6B-Q4_K_M`) proposes candidate tokens that the main model (`Qwen3-14B-Q8_0`) verifies in parallel. This yields significant speedups for tool-calling workloads where output patterns are predictable.

| Draft Parameter | Value |
|----------------|-------|
| `--draft-max` | `16` |
| `--draft-min` | `1` |
| `--draft-p-min` | `0.75` |

#### Running

The full launch command is in [`llama-cpp.txt`](conversational-agent-llm/llama-cpp.txt). Run it with:

```bash
llama-server $(cat conversational-agent-llm/llama-cpp.txt | tr '\n' ' ')
```

Or use the [llama.cpp Docker image](https://github.com/ggml-org/llama.cpp/blob/master/docs/docker.md) with the same parameters.

#### Benchmarks (NVIDIA GB10 — DGX Spark)

Tested across 20 different home automation commands with 3 repetitions each:

| Metric | Result |
|--------|--------|
| Accuracy | **100%** (60/60 correct) |
| Average Latency | **437 ms** |
| Min Latency | 293 ms |
| Max Latency | 918 ms |

Full benchmark results with per-command breakdown: [`qwen3-benchmarks.md`](conversational-agent-llm/qwen3-benchmarks.md)

---

### 4. Text-to-Speech (TTS) — Kokoro FastAPI

**Directory:** [`text-to-speech/`](text-to-speech/)

Converts LLM responses back to natural-sounding speech using [Kokoro FastAPI](https://github.com/remsky/Kokoro-FastAPI), a GPU-accelerated ONNX TTS engine. A [Wyoming-OpenAI bridge](https://github.com/roryeckel/wyoming_openai) translates between the Wyoming protocol and Kokoro's OpenAI-compatible API.

This stack consists of two services:

#### Kokoro FastAPI (TTS Engine)

| Setting | Value |
|---------|-------|
| Image | `kokoro-fastapi-gpu:local` (locally built) |
| Port | `8880` |
| ONNX GPU | `True` |
| ONNX Threads | `12` |
| Inter-Op Threads | `6` |
| Execution Mode | `parallel` |
| Optimization Level | `all` |

#### Wyoming-OpenAI Bridge

| Setting | Value |
|---------|-------|
| Image | `ghcr.io/roryeckel/wyoming_openai:latest` |
| Port | `10900` (exposed) → `10300` (internal) |
| Voice | `af_sky` |
| Speed | `1.1x` |
| Streaming | Enabled (min 6 words, max 220 chars) |

The bridge exposes a Wyoming-compatible endpoint on port `10900` that Home Assistant can discover and use as a TTS provider.

#### Building for ARM64 (DGX Spark)

The upstream Kokoro FastAPI Dockerfile uses `--platform=$BUILDPLATFORM` which breaks native ARM64 builds. The included patch script fixes this:

```bash
bash text-to-speech/kokorofastapi-arm64-build-patch.sh
```

This script:
1. Pulls the latest Kokoro FastAPI source
2. Patches the Dockerfile to remove the platform constraint
3. Builds a native ARM64 GPU image as `kokoro-fastapi-gpu:local`
4. Restarts the compose stack

For x86/x64, you can build or pull the image directly without the patch.

```bash
docker compose -f text-to-speech/compose.kokorofastapi.yml up -d
```

#### Volume Configuration

The `kokoro.env` file is mounted into the container and controls runtime settings like `default_volume_multiplier=3.0`. Place your model files in `/opt/models/kokoro`.

---

## Port Reference

| Service | Port | Protocol |
|---------|------|----------|
| Wake Word (OpenWakeWord) | `10400` | TCP/UDP |
| Speech-to-Text (ONNX ASR) | `10300` | TCP |
| Speaker Verification (Voice Match) | `10350` | TCP |
| LLM (llama.cpp) | `8080` | HTTP |
| TTS Engine (Kokoro FastAPI) | `8880` | HTTP |
| TTS Bridge (Wyoming-OpenAI) | `10900` | TCP |

---

## Home Assistant Integration

Once all services are running, add them as Wyoming protocol integrations in Home Assistant:

1. **Settings** → **Devices & Services** → **Add Integration** → **Wyoming Protocol**
2. Add each service by its host and port:
   - Wake Word: `<host>:10400`
   - STT: `<host>:10300` (or `<host>:10350` if using Voice Match)
   - TTS: `<host>:10900`
3. Configure the **Conversation Agent** to use the llama.cpp instance (`http://<host>:8080/v1`) via an OpenAI-compatible integration
4. Create a **Voice Assistant** pipeline combining all four components

---

## Hardware Tested

- **NVIDIA DGX Spark** (ARM64, GB10 GPU) — full stack, all components
- **x86/x64** systems with NVIDIA GPUs (CUDA-capable)

## License

[MIT](LICENSE) — Xavier Larrea, 2026
