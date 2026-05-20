# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Install dependencies
uv sync

# Launch Gradio Web UI (http://localhost:7860)
uv run acestep

# Launch REST API server (http://localhost:8001)
uv run acestep-api

# Download models manually
uv run acestep-download
```

## Testing

Uses `unittest` framework. Test files follow `*_test.py` or `test_*.py` naming.

```bash
# All tests
uv run python -m unittest discover -s . -p "*_test.py"
uv run python -m unittest discover -s . -p "test_*.py"

# Single test file
uv run python -m unittest acestep.training.test_lora_utils

# Single test class/method
uv run python -m unittest acestep.training.test_lora_utils.TestUnwrapDecoder.test_returns_module_directly

# Tests in a directory
uv run python -m unittest discover -s acestep/training -p "*_test.py"
```

## Architecture

### Generation Pipeline

```
User Request → LLMHandler (Chain-of-Thought planning) → AceStepHandler (DiT diffusion) → VAE decode → Audio output
```

- **AceStepHandler** (`handler.py`): Composes ~20 mixin classes from `core/generation/handler/`. Holds DiT model, VAE, text_encoder. Orchestrates the full generation pipeline.
- **LLMHandler** (`llm_inference.py`): Manages 5Hz LM (0.6B/1.7B/4B). Supports backends: `vllm` (nano-vllm bundled in `third_parts/`), `pt` (PyTorch native), `mlx` (Apple Silicon).
- **GenerationParams** (`inference.py`): Dataclass with all generation parameters. `generate_music()` is the main orchestration function.

### GPU Memory Management

`gpu_config.py` detects hardware and returns a `GPUConfig` with tier, VRAM limits, batch limits, and offload strategy. The system auto-offloads DiT/VAE/text_encoder between GPU↔CPU based on available VRAM, and applies INT8 quantization on lower tiers.

### Entry Points (pyproject.toml)

| Command | Module | Purpose |
|---------|--------|---------|
| `acestep` | `acestep.acestep_v15_pipeline:main` | Gradio UI |
| `acestep-api` | `acestep.api_server:main` | FastAPI REST server |
| `acestep-download` | `acestep.model_downloader:main` | Model downloader |

### API Server (`api_server.py`)

FastAPI with in-memory job queue. Key endpoints:
- `POST /release_task` → returns `task_id`
- `POST /query_result` → poll task status/audio URL
- `GET /v1/models`, `GET /health`, `GET /v1/audio`

Job lifecycle: `release_task` → `worker_runtime` picks up → `AceStepHandler.generate_music()` → result cached.

### Generation Handler Mixins (`core/generation/handler/`)

50+ mixin files, each single-responsibility (~150 LOC target). Key ones:
- `diffusion.py`: ODE/SDE sampling (Euler, Heun)
- `conditioning_*.py`: Text/audio conditioning
- `vae_decode_chunks.py` / `vae_encode_chunks.py`: Chunked VAE for low VRAM
- `init_service_offload_context.py`: GPU↔CPU offload orchestration
- `lora_*.py`: LoRA adapter injection
- `mlx_*.py`: Apple Silicon acceleration

### Training (`training/`)

LoRA/LoKR fine-tuning via PyTorch Lightning. Flow: audio collection → `DatasetBuilder` annotation → `PreprocessedDataModule` → `LoRATrainer.train()` → `inject_lora_into_dit()` at inference.

### UI (`ui/gradio/`)

Gradio Blocks interface with tabs (Simple, Custom, Remix, Extract, Training, Settings). i18n system supports 50+ languages via translation files in `ui/gradio/i18n/`.

## Configuration

`.env` file (survives `git pull`). Key variables: `ACESTEP_CONFIG_PATH` (DiT model), `ACESTEP_LM_MODEL_PATH` (LM model), `ACESTEP_LM_BACKEND` (vllm/pt/mlx), `ACESTEP_DEVICE`, `ACESTEP_INIT_LLM`. See `.env.example` for full list.

## Code Conventions

- **Style**: PEP 8, double quotes, `loguru` logger (not `print()`)
- **Module size**: ≤150 LOC optimal, 200 LOC hard cap
- **Multi-platform**: CUDA, ROCm, Intel XPU, MPS, MLX, CPU. Do not alter non-target platform paths.
- **Dependencies**: `uv add <package>`
- Refer to `AGENTS.md` for detailed scope control, decomposition policy, and PR guidelines.
