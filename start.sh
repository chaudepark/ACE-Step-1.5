#!/usr/bin/env bash
# ACE-Step UI launcher: auto-loads .env, auto-initializes models on startup,
# and applies persistent settings (batch_size from .env, browser localStorage
# for inference_steps/shift/use_adg/duration/duration_auto).
#
# Usage: ./start.sh [extra args forwarded to acestep CLI]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${ACESTEP_CONFIG_PATH:=acestep-v15-turbo}"
: "${ACESTEP_LM_MODEL_PATH:=acestep-5Hz-lm-0.6B}"
: "${ACESTEP_LM_BACKEND:=pt}"
: "${ACESTEP_BATCH_SIZE:=1}"
: "${ACESTEP_UI_LANGUAGE:=${LANGUAGE:-en}}"
# Default to WAV: MP3 export needs system FFmpeg (libavutil) via torchcodec
# which is not present in minimal WSL2 setups. WAV is lossless and works
# without extra dependencies. Override to "mp3"/"flac"/etc. only after
# installing ffmpeg.
: "${ACESTEP_AUDIO_FORMAT:=wav}"
export ACESTEP_AUDIO_FORMAT

echo "Launching ACE-Step UI with:"
echo "  DiT model    : $ACESTEP_CONFIG_PATH"
echo "  LM model     : $ACESTEP_LM_MODEL_PATH"
echo "  Backend      : $ACESTEP_LM_BACKEND"
echo "  Batch size   : $ACESTEP_BATCH_SIZE"
echo "  Language     : $ACESTEP_UI_LANGUAGE"
echo "  Audio format : $ACESTEP_AUDIO_FORMAT"

exec uv run acestep \
  --init_service true \
  --config_path "$ACESTEP_CONFIG_PATH" \
  --lm_model_path "$ACESTEP_LM_MODEL_PATH" \
  --backend "$ACESTEP_LM_BACKEND" \
  --batch_size "$ACESTEP_BATCH_SIZE" \
  --language "$ACESTEP_UI_LANGUAGE" \
  "$@"
