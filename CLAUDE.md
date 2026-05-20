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

## Post-Generation Hook and Auto-Sampling Loop

This fork adds an opt-in pipeline that off-loads every generated audio
file to Demucs for stem separation and uploads the original + 4 stems
to Google Drive. On top of that, a systemd user timer drives a fully
autonomous "sample mining" loop that generates fresh material every
hour and pushes the stems to the same Drive folder.

### Data flow

```
cli.py / Gradio UI
   ↓ writes <uuid>.wav + <uuid>.json sidecar to OUTPUT_DIR
   ↓
post_generation_hook.run_post_generation_hook()
   ↓ launches ACESTEP_POST_HOOK detached (default = separate.sh)
   ↓
separate.sh <wav>
   ├─ flock-serialize (logs/.separate.lock) — one demucs at a time
   ├─ parse sidecar JSON → genre/bpm/key slug for naming
   ├─ Try 1: htdemucs_ft (bag-of-4, timeout 30 min)
   │     fail → Try 2: htdemucs (single, timeout 10 min)
   │             success tags stems with _FALLBACK suffix
   ├─ Create Drive folder <stamp>_<genre>_<bpm>_<key>_NNN
   ├─ Upload original + vocals/drums/bass/other via gws
   └─ trash-put the wav + json (recoverable, never `rm`)
```

For the autonomous loop, prepend:

```
systemd user timer (hourly, see ~/.config/systemd/user/ace-auto-generate.{service,timer})
   ↓
auto_generate.sh
   ├─ flock-serialize (auto_sample/.auto_generate.lock)
   ├─ Orphan sweep: any leftover wav in auto_sample/output → separate.sh
   ├─ pick_caption.py --mode auto → composes TOML from templates.json
   ├─ uv run python cli.py -c <toml> --backend pt   (empty stdin)
   └─ separate.sh <new wav>   (synchronous, NOT '&')
```

### Why synchronous separate.sh inside auto_generate.sh

The systemd service is `Type=oneshot`. Default `KillMode=control-group`
kills any backgrounded process when ExecStart exits. The original
implementation launched `separate.sh &` and got its child reaped before
demucs could finish. The fix: always call separate.sh in the foreground
so it stays inside the service's lifetime. One cycle is ~4-5 min, well
within the hourly timer.

### CLI quirks you will hit if you reuse cli.py

1. **8 GB VRAM needs `--backend pt`.** The default `vllm` backend pre-allocates
   a KV cache block large enough to fail with `Insufficient KV cache` on
   tier-3 GPUs. `.env`'s `ACESTEP_LM_BACKEND` is **not** read by `cli.py`
   directly — pass `--backend pt` on the command line.
2. **`thinking=true` + text2music blocks on `input()`.** When the prompt
   edit hook is installed (any CoT flag enabled for a non-cover task)
   `cli.py` writes `instruction.txt`, calls `input()`, and waits. There
   are two ways through this: (a) pre-create `instruction.txt` so the
   "found, using without editing" path triggers, or (b) pipe an empty
   line: `echo "" | uv run python cli.py …`. `auto_generate.sh` uses
   (b) and deletes any stale `instruction.txt` before each run so the
   LM's fresh output is always used.
3. **`cover` task skips the LM entirely.** Search `skip_lm_tasks` in
   `cli.py`. This is the single most important fact for sample-mining:
   `cover` is fast (~5-20 s per track), avoids the LM's pop/rock genre
   bias, and lets you bend an arbitrary reference audio toward a target
   style via `audio_cover_strength` + Caption alone.

### Caption strategy that survives the LM bias

Two empirical findings from this codebase's previous failures:

- **The LM defaults toward rock/pop.** Any text2music run without
  explicit negatives risks getting electric guitar even when you asked
  for ambient chiptune. Put `no rock`, `no electric guitar`, `no metal`
  in every Caption that isn't a rock genre. `auto_sample/templates.json`
  encodes per-genre negatives that `pick_caption.py` always appends.
- **`audio_cover_strength` is the lever for source preservation.**
  0.80–0.85 keeps the reference recognizable (same genre, fresh take),
  0.55–0.70 lets the Caption push the style elsewhere (genre transfer),
  0.20–0.30 makes the reference a loose mood reference. Lower values
  are needed for big stylistic jumps, but the LM bias also gets stronger,
  so be diligent with negatives at low strength.

### Repository layout for the loop

| Path | Role |
|------|------|
| `separate.sh` | Demucs fallback chain + Drive upload (called by hook) |
| `auto_generate.sh` | One iteration of: orphan sweep → caption → cli.py → separate |
| `auto_sample/templates.json` | Genre × mood × texture pools + vocal-lyrics filler |
| `auto_sample/pick_caption.py` | Randomly composes a TOML config per run |
| `auto_sample/build_source_index.sh` | Flat index of audio files under `/mnt/d/music_extracted` |
| `auto_sample/logs/`, `toml/`, `output/`, `source_index.txt`, `.auto_generate.lock` | Runtime only (gitignored) |
| `systemd/ace-auto-generate.service.template` | systemd unit template with `@PROJECT_ROOT@`/`@EXTRA_PATH@` placeholders |
| `systemd/ace-auto-generate.timer` | Hourly trigger (no substitution needed) |
| `systemd/install.sh` | Per-host installer — auto-detects paths, writes units to `~/.config/systemd/user/`, enables timer |
| `~/.config/systemd/user/ace-auto-generate.{service,timer}` | Generated by `systemd/install.sh`, **not in repo** |
| `logs/separate/<stamp>-<basename>.log` | Per-invocation separate.sh logs (gitignored) |

### Required `.env` keys for the hook to fire

```ini
ACESTEP_POST_HOOK=/abs/path/to/separate.sh   # absence = hook disabled (no-op)
ACESTEP_DRIVE_FOLDER_ID=<google-drive-folder-id>
# Optional overrides honored by separate.sh:
# SEPARATE_DEVICE=cpu|cuda                   (default cpu)
# SEPARATE_MODEL=htdemucs_ft                 (primary)
# SEPARATE_FALLBACK_MODEL=htdemucs           (used when primary fails)
# SEPARATE_PRIMARY_TIMEOUT=1800              (seconds)
# SEPARATE_FALLBACK_TIMEOUT=600
```

`gws` (the Drive CLI used for uploads) lives in `~/.cargo/bin`, which
is **not** on systemd's default `PATH`. The user service hardcodes
`Environment=PATH=/home/sarai/.cargo/bin:/home/sarai/.local/bin:…` —
when migrating to a new host, edit that line to match.

### Remote layout (this checkout only, not enforced by code)

This fork follows the standard upstream/origin split:

- `origin` → personal fork (push your customizations here)
- `upstream` → ACE-Step developer repo (pull-only for their updates)

To absorb upstream changes:

```bash
git fetch upstream
git merge upstream/main      # or rebase
git push origin main
```

On a fresh clone of the personal fork, `upstream` has to be added back
by hand (`git remote add upstream …`).

### Migrating to a new host

Most of the loop is captured in the repo. A new machine needs roughly:

```bash
# 1. Clone the personal fork and re-add upstream
git clone git@github.com:chaudepark/ACE-Step-1.5.git
cd ACE-Step-1.5
git remote add upstream https://github.com/ACE-Step/ACE-Step-1.5.git

# 2. External tools the loop depends on
curl -LsSf https://astral.sh/uv/install.sh | sh        # uv
uv tool install demucs                                  # stem separation
sudo apt install trash-cli                              # trash-put
# gws (Google Workspace CLI): see https://github.com/Toshakins/gws
#   (or your preferred Drive uploader; separate.sh shells out via gws drive files create)

# 3. Project deps
uv sync

# 4. Personal config — copy .env.example and fill in:
cp .env.example .env
# Edit .env:
#   ACESTEP_POST_HOOK=<abs path>/separate.sh
#   ACESTEP_DRIVE_FOLDER_ID=<your drive folder id>
#   ACESTEP_AUTO_DEFAULT=<true|false>
#   plus any model/backend overrides

# 5. Source library for cover mode
#    auto_sample/build_source_index.sh defaults to /mnt/d/music_extracted.
#    Either replicate that path or override via ACE_SOURCE_ROOT:
ACE_SOURCE_ROOT=/path/to/your/audio ./auto_sample/build_source_index.sh

# 6. systemd user units (installs into ~/.config/systemd/user/, enables timer)
./systemd/install.sh
#    Add --no-enable to install without auto-starting.
#    Add --uninstall to remove.

# 7. WSL2 only: enable user lingering so the timer survives logout
sudo loginctl enable-linger "$USER"
```

The install script auto-detects PATH directories for `uv`, `gws`,
`demucs`, and `trash-put` and bakes them into the service's
`Environment=PATH=` line, so the unit doesn't have to be hand-edited
when those tools live in non-default locations.
