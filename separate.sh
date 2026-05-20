#!/usr/bin/env bash
# ACE-Step post-generation hook: 4-stem separate via Demucs and upload
# the original + all stems to a Google Drive folder via `gws`.
#
# Invoked by acestep/ui/gradio/events/results/post_generation_hook.py as:
#   separate.sh /abs/path/to/audio.wav
#
# Environment (loaded from .env if present):
#   ACESTEP_DRIVE_FOLDER_ID   required — Drive parent folder ID
#   SEPARATE_DEVICE           optional — "cpu" (default) or "cuda"
#   SEPARATE_MODEL            optional — Demucs model (default htdemucs_ft)
#
# Logs:
#   logs/separate/YYYYMMDD-HHMMSS-<basename>.log
#   One file per invocation so individual runs are easy to read and the
#   context window isn't wasted scrolling a 2000-line daily log.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="$SCRIPT_DIR/logs/separate"
mkdir -p "$LOG_DIR"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_BASENAME=""
if [[ -n "${1:-}" ]]; then
  RUN_BASENAME="$(basename "${1%.*}")"
fi
LOG_FILE="$LOG_DIR/${RUN_STAMP}${RUN_BASENAME:+-$RUN_BASENAME}.log"

log() { echo "[$(date '+%F %T')] $*" >>"$LOG_FILE"; }

# Redirect all subsequent output to the log so a misbehaving child can't
# leak to the Gradio UI process.
exec >>"$LOG_FILE" 2>&1

# Serialize: htdemucs_ft on CPU pegs all cores and loads ~6GB of model
# weights. Running two in parallel causes OOM kills and 2-3x slowdown
# from cache thrashing. Queue invocations behind a single file lock so
# each track is processed in sequence.
LOCK_FILE="$SCRIPT_DIR/logs/.separate.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "QUEUED: another separation is running, waiting for lock..."
  flock 9
  log "LOCK ACQUIRED, proceeding"
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

IN="${1:-}"
if [[ -z "$IN" || ! -f "$IN" ]]; then
  log "ERROR: input file missing: ${IN:-<none>}"
  exit 1
fi

: "${ACESTEP_DRIVE_FOLDER_ID:?ACESTEP_DRIVE_FOLDER_ID is required}"
: "${SEPARATE_DEVICE:=cpu}"
: "${SEPARATE_MODEL:=htdemucs_ft}"

if ! command -v demucs >/dev/null 2>&1; then
  log "ERROR: demucs not found in PATH. Install with: uv tool install demucs"
  exit 1
fi
if ! command -v gws >/dev/null 2>&1; then
  log "ERROR: gws not found in PATH."
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BASE="$(basename "${IN%.*}")"
WORK_DIR="$(mktemp -d -t acestep-sep-XXXX)"

# Extract genre/bpm/key from the sidecar JSON written by generation_progress.py
# (same dir, same basename, .json extension). Falls back to safe defaults if
# the file is missing or malformed.
JSON_PATH="${IN%.*}.json"
META_TSV="$(python3 - "$JSON_PATH" <<'PY' 2>/dev/null || echo $'music\tunkbpm\tUnk'
import json, pathlib, re, sys

# Match longer/compound genres first so "drum and bass" wins over "drum".
GENRES = [
    "drum and bass", "drum-and-bass", "drum n bass",
    "trip-hop", "trip hop", "hip-hop", "hip hop",
    "lo-fi", "lo fi", "lofi", "big beat", "new age",
    "bossa nova", "jazz-funk", "soul-funk",
    "psychedelic rock", "garage rock", "post-rock",
    "synthwave", "vaporwave", "darkwave",
    "breakbeat", "jungle", "dubstep", "drum'n'bass",
    "afrobeat", "g-funk", "boom bap",
    "funk", "soul", "jazz", "rock", "pop", "ambient", "drone",
    "classical", "electronic", "techno", "house", "trap",
    "rnb", "r&b", "blues", "gospel", "country", "folk",
    "reggae", "ska", "latin", "samba", "disco", "idm",
    "indie", "metal", "punk", "soundscape",
]

try:
    data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    data = {}

caption = (data.get("caption") or "").lower()
genre = next((g for g in GENRES if g in caption), "music")
genre_slug = re.sub(r"[^a-z0-9]+", "-", genre).strip("-") or "music"

bpm_raw = data.get("bpm")
try:
    bpm_slug = f"{int(float(bpm_raw))}bpm"
except (TypeError, ValueError):
    bpm_slug = "unkbpm"

key_raw = (data.get("keyscale") or data.get("key_scale") or data.get("key") or "").strip()
m = re.match(r"^([A-Ga-g][#b]?)\s*(major|minor|maj|min)?", key_raw, re.IGNORECASE)
if m:
    root = m.group(1).upper()
    mode = (m.group(2) or "").lower()
    key_slug = f"{root}m" if mode.startswith("min") else root
else:
    key_slug = "Unk"
# Strip filesystem-unfriendly chars but keep '#' for sharps.
key_slug = re.sub(r"[^A-Za-z0-9#]", "", key_slug) or "Unk"

print(f"{genre_slug}\t{bpm_slug}\t{key_slug}")
PY
)"
IFS=$'\t' read -r GENRE_SLUG BPM_SLUG KEY_SLUG <<<"$META_TSV"
META_TAG="${GENRE_SLUG}_${BPM_SLUG}_${KEY_SLUG}"
log "metadata: genre=$GENRE_SLUG bpm=$BPM_SLUG key=$KEY_SLUG (from ${JSON_PATH})"

cleanup() {
  if command -v trash-put >/dev/null 2>&1; then
    trash-put "$WORK_DIR" 2>/dev/null || true
  else
    # Fallback: leave for manual cleanup rather than `rm -rf`.
    log "trash-put unavailable; leaving $WORK_DIR for manual cleanup"
  fi
}
trap cleanup EXIT

log "START $IN (primary=$SEPARATE_MODEL device=$SEPARATE_DEVICE)"

# Run demucs with the given model and a wall-clock timeout. With
# --filename "{stem}.{ext}" demucs writes flat into <out>/<model>/.
# Returns 0 (and sets STEM_DIR) only when vocals.wav was actually produced.
STEM_DIR=""
run_demucs() {
  local model="$1"
  local timeout_sec="$2"
  local stem_dir="$WORK_DIR/$model"
  log "demucs start: model=$model timeout=${timeout_sec}s"
  if timeout --signal=TERM --kill-after=30 "${timeout_sec}" \
      demucs -n "$model" -d "$SEPARATE_DEVICE" \
      -o "$WORK_DIR" --filename "{stem}.{ext}" "$IN"; then
    if [[ -f "$stem_dir/vocals.wav" ]]; then
      STEM_DIR="$stem_dir"
      log "demucs success: model=$model stems=$stem_dir"
      return 0
    fi
    log "WARN: $model exited 0 but no vocals.wav at $stem_dir"
  else
    log "WARN: $model failed or timed out (rc=$?)"
  fi
  return 1
}

# Fallback chain: try high-quality htdemucs_ft (bag-of-4) first; if it
# fails or times out, fall back to single-model htdemucs which uses far
# less memory and finishes in ~1 min. Fallback-derived stems are tagged
# _FALLBACK so they can be identified and optionally re-processed later.
FALLBACK_TAG=""
PRIMARY_TIMEOUT="${SEPARATE_PRIMARY_TIMEOUT:-1800}"   # 30 min
FALLBACK_TIMEOUT="${SEPARATE_FALLBACK_TIMEOUT:-600}"  # 10 min
FALLBACK_MODEL="${SEPARATE_FALLBACK_MODEL:-htdemucs}"

if ! run_demucs "$SEPARATE_MODEL" "$PRIMARY_TIMEOUT"; then
  log "PRIMARY MODEL FAILED — attempting fallback model=$FALLBACK_MODEL"
  if [[ "$FALLBACK_MODEL" == "$SEPARATE_MODEL" ]]; then
    log "ERROR: fallback model equals primary; nothing else to try"
    exit 1
  fi
  if ! run_demucs "$FALLBACK_MODEL" "$FALLBACK_TIMEOUT"; then
    log "ERROR: both primary and fallback models failed; leaving $IN in place"
    exit 1
  fi
  FALLBACK_TAG="_FALLBACK"
  log "FALLBACK SUCCEEDED — stems will be tagged with $FALLBACK_TAG"
fi

# Find the next sequence suffix so rclone mirrors never see duplicate names.
# Look up sibling folders sharing the same `<stamp>_<meta>` prefix and pick
# the smallest unused `_NNN` (zero-padded, 3 digits).
BASE_NAME="${STAMP}_${META_TAG}"
LIST_OUT="$(gws drive files list --params "{\"q\":\"'${ACESTEP_DRIVE_FOLDER_ID}' in parents and name contains '${BASE_NAME}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false\",\"fields\":\"files(name)\",\"pageSize\":200}" 2>&1 || true)"
# Compute next sequence via a heredoc-free python -c invocation. The previous
# heredoc + pipe + || combination tripped a bash parser quirk at runtime
# even though `bash -n` accepted it. Keep the fallback outside the
# command substitution to stay clear of that interaction.
NEXT_SEQ_RAW="$(printf '%s' "$LIST_OUT" | python3 -c '
import json, re, sys
data = sys.stdin.read()
m = re.search(r"\{.*\}", data, re.DOTALL)
prefix = sys.argv[1]
nums = []
if m:
    try:
        payload = json.loads(m.group(0))
    except json.JSONDecodeError:
        payload = {}
    for f in payload.get("files", []) or []:
        mm = re.match(r"^" + re.escape(prefix) + r"_(\d+)$", f.get("name", ""))
        if mm:
            nums.append(int(mm.group(1)))
nxt = (max(nums) + 1) if nums else 1
print(f"{nxt:03d}")
' "$BASE_NAME" 2>/dev/null)"
NEXT_SEQ="${NEXT_SEQ_RAW:-001}"
FOLDER_NAME="${BASE_NAME}_${NEXT_SEQ}"
FOLDER_JSON="$(gws drive files create \
  --json "{\"name\":\"$FOLDER_NAME\",\"parents\":[\"$ACESTEP_DRIVE_FOLDER_ID\"],\"mimeType\":\"application/vnd.google-apps.folder\"}" \
  2>&1)" || {
  log "ERROR: failed to create Drive folder: $FOLDER_JSON"
  exit 1
}
# gws prints a "Using keyring backend: …" status line before the JSON body,
# so we have to extract just the {…} block instead of feeding the whole
# stream to json.load.
NEW_FOLDER_ID="$(echo "$FOLDER_JSON" | python3 -c '
import sys, json, re
data = sys.stdin.read()
m = re.search(r"\{.*\}", data, re.DOTALL)
if m:
    try:
        print(json.loads(m.group(0)).get("id", ""))
    except json.JSONDecodeError:
        pass
' 2>/dev/null || echo "")"
if [[ -z "$NEW_FOLDER_ID" ]]; then
  log "ERROR: could not parse folder id from: $FOLDER_JSON"
  exit 1
fi
log "Drive folder created: $FOLDER_NAME ($NEW_FOLDER_ID)"

# gws restricts --upload to paths inside the current working directory, so
# stage every file inside $WORK_DIR and invoke gws from there with a
# relative path. We use a dedicated subdir to keep uploads grouped.
STAGE_DIR="$WORK_DIR/upload"
mkdir -p "$STAGE_DIR"
EXT="${IN##*.}"
cp -- "$IN" "$STAGE_DIR/original.${EXT}"
for stem in vocals drums bass other; do
  f="$STEM_DIR/${stem}.wav"
  if [[ -f "$f" ]]; then
    cp -- "$f" "$STAGE_DIR/${stem}.wav"
  else
    log "WARN: missing stem $f"
  fi
done

upload() {
  local relative_path="$1"
  local remote_name="$2"
  if gws drive files create \
    --json "{\"name\":\"$remote_name\",\"parents\":[\"$NEW_FOLDER_ID\"]}" \
    --upload "$relative_path" >/dev/null; then
    log "uploaded: $remote_name"
  else
    log "ERROR: failed to upload $remote_name (gws exit $?)"
    return 1
  fi
}

cd "$STAGE_DIR"
UPLOAD_FAILED=0
upload "original.${EXT}" "${META_TAG}_original.${EXT}" || UPLOAD_FAILED=1
for stem in vocals drums bass other; do
  if [[ -f "${stem}.wav" ]]; then
    upload "${stem}.wav" "${META_TAG}_${stem}${FALLBACK_TAG}.wav" || UPLOAD_FAILED=1
  fi
done
cd "$SCRIPT_DIR"

if [[ "$UPLOAD_FAILED" -ne 0 ]]; then
  log "ERROR: one or more uploads failed; leaving $IN in place for retry"
  exit 1
fi

log "DONE $IN → Drive/$FOLDER_NAME"

# All stems uploaded successfully — the local source is now redundant
# (Mac syncs from Drive). trash-put (not rm) so accidental losses can
# be recovered from the trash for ~7 days.
if command -v trash-put >/dev/null 2>&1; then
  trash-put -- "$IN" 2>/dev/null && log "trashed source: $IN"
  if [[ -f "$JSON_PATH" ]]; then
    trash-put -- "$JSON_PATH" 2>/dev/null && log "trashed sidecar: $JSON_PATH"
  fi
  # Remove the batch directory only if it became empty.
  BATCH_DIR="$(dirname "$IN")"
  if [[ -d "$BATCH_DIR" ]] && [[ -z "$(ls -A "$BATCH_DIR" 2>/dev/null)" ]]; then
    rmdir -- "$BATCH_DIR" 2>/dev/null && log "removed empty batch dir: $BATCH_DIR"
  fi
else
  log "trash-put unavailable; leaving $IN in place"
fi
