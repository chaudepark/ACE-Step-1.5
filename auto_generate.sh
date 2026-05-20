#!/usr/bin/env bash
# auto_generate.sh — 1 iteration of: pick caption → cli.py generate → separate.sh
#
# Workflow:
#   1. flock-serialize so only one instance runs at a time
#   2. Pick mode (cover/t2m) and Caption via auto_sample/pick_caption.py
#   3. For cover: pick a random source from auto_sample/source_index.txt
#   4. Write TOML to auto_sample/toml/<stamp>.toml
#   5. Delete stale instruction.txt and run cli.py --backend pt (pipe empty stdin)
#   6. Find resulting WAV and hand off to separate.sh
#
# Logs:
#   auto_sample/logs/<stamp>.log per run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_DIR="$SCRIPT_DIR/auto_sample"
TOML_DIR="$AUTO_DIR/toml"
LOG_DIR="$AUTO_DIR/logs"
OUTPUT_DIR="$AUTO_DIR/output"
SOURCE_INDEX="$AUTO_DIR/source_index.txt"
SEPARATE_SH="$SCRIPT_DIR/separate.sh"
PICK_CAPTION="$AUTO_DIR/pick_caption.py"
INSTRUCTION_TXT="$SCRIPT_DIR/instruction.txt"
LOCK_FILE="$AUTO_DIR/.auto_generate.lock"
DURATION="${ACE_AUTO_DURATION:-110}"

mkdir -p "$TOML_DIR" "$LOG_DIR" "$OUTPUT_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/${STAMP}.log"
exec >>"$LOG_FILE" 2>&1

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
log "=== auto_generate start (stamp=$STAMP) ==="

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "ANOTHER RUN HOLDS LOCK; exiting"
  exit 0
fi
log "lock acquired"

cd "$SCRIPT_DIR"

# Orphan sweep: prior runs may have left a wav (with sidecar) in $OUTPUT_DIR
# because separation crashed / OOM'd / was kill'd by systemd cgroup. Pick
# those up first so they don't pile up. separate.sh has its own fallback
# chain, so even a previously-failed run gets a second chance here.
shopt -s nullglob
for orphan in "$OUTPUT_DIR"/*.wav; do
  log "orphan from previous run: $orphan"
  if [[ -x "$SEPARATE_SH" ]]; then
    if "$SEPARATE_SH" "$orphan"; then
      log "orphan recovered: $orphan"
    else
      log "orphan recovery failed (will retry next cycle): $orphan"
    fi
  fi
done
shopt -u nullglob

# Determine mode: respect ACE_AUTO_MODE env, else auto
MODE="${ACE_AUTO_MODE:-auto}"
log "requested mode=$MODE"

# For cover mode, we need a source. Decide upfront so pick_caption.py knows.
SRC_AUDIO=""
if [[ "$MODE" == "auto" || "$MODE" == "cover" ]]; then
  if [[ ! -s "$SOURCE_INDEX" ]]; then
    log "source index missing or empty; attempting to build"
    "$AUTO_DIR/build_source_index.sh" || true
  fi
  if [[ -s "$SOURCE_INDEX" ]]; then
    SRC_AUDIO="$(shuf -n 1 "$SOURCE_INDEX")"
    log "picked source candidate: $SRC_AUDIO"
  else
    log "no source available; forcing mode=t2m"
    MODE="t2m"
  fi
fi

TOML_PATH="$TOML_DIR/${STAMP}.toml"
PICK_ARGS=(--mode "$MODE" --output "$TOML_PATH" --save-dir "$OUTPUT_DIR" --duration "$DURATION")
if [[ "$MODE" != "t2m" && -n "$SRC_AUDIO" ]]; then
  PICK_ARGS+=(--src-audio "$SRC_AUDIO")
fi

log "running pick_caption.py ${PICK_ARGS[*]}"
PICK_OUT="$(uv run python "$PICK_CAPTION" "${PICK_ARGS[@]}")"
log "pick result: $PICK_OUT"

# Detect actual mode chosen by pick_caption (auto resolves at random)
ACTUAL_MODE="$(grep -oP 'mode=\K[^ ]+' <<<"$PICK_OUT" || true)"
log "actual mode=$ACTUAL_MODE"

# For t2m we must avoid blocking on input(); delete stale instruction.txt so
# cli.py treats this run as fresh, then pipe a single newline.
if [[ "$ACTUAL_MODE" == "t2m" ]]; then
  if [[ -f "$INSTRUCTION_TXT" ]]; then
    log "removing stale instruction.txt"
    rm -f "$INSTRUCTION_TXT"
  fi
fi

# Snapshot output dir to identify newly written file later.
BEFORE_LIST="$(mktemp)"
ls -1 "$OUTPUT_DIR" 2>/dev/null | sort > "$BEFORE_LIST" || true

log "launching cli.py"
set +e
echo "" | uv run python "$SCRIPT_DIR/cli.py" -c "$TOML_PATH" --backend pt
CLI_RC=$?
set -e
log "cli.py exit code=$CLI_RC"

if [[ $CLI_RC -ne 0 ]]; then
  log "cli.py failed; aborting"
  rm -f "$BEFORE_LIST"
  exit $CLI_RC
fi

AFTER_LIST="$(mktemp)"
ls -1 "$OUTPUT_DIR" 2>/dev/null | sort > "$AFTER_LIST" || true
NEW_FILES="$(comm -13 "$BEFORE_LIST" "$AFTER_LIST" | grep -E '\.(wav|mp3|flac)$' || true)"
rm -f "$BEFORE_LIST" "$AFTER_LIST"

if [[ -z "$NEW_FILES" ]]; then
  log "no new audio file detected in $OUTPUT_DIR"
  exit 1
fi

# Write a sidecar JSON with caption/lyrics info so separate.sh's metadata pipeline works.
TOML_CONTENT="$(cat "$TOML_PATH")"
while IFS= read -r f; do
  WAV_PATH="$OUTPUT_DIR/$f"
  JSON_PATH="${WAV_PATH%.*}.json"
  if [[ ! -f "$JSON_PATH" ]]; then
    log "writing sidecar JSON: $JSON_PATH"
    python3 -c '
import json, re, sys
toml = sys.argv[1]
caption = re.search(r"^caption\s*=\s*\"(.*)\"\s*$", toml, re.M)
bpm = re.search(r"^bpm\s*=\s*(\d+)", toml, re.M)
key = re.search(r"^keyscale\s*=\s*\"([^\"]+)\"", toml, re.M)
task = re.search(r"^task_type\s*=\s*\"([^\"]+)\"", toml, re.M)
src = re.search(r"^src_audio\s*=\s*\"([^\"]+)\"", toml, re.M)
payload = {
    "caption": caption.group(1) if caption else "",
    "bpm": int(bpm.group(1)) if bpm else None,
    "keyscale": key.group(1) if key else "",
    "task_type": task.group(1) if task else "",
    "src_audio": src.group(1) if src else "",
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
' "$TOML_CONTENT" > "$JSON_PATH"
  fi
  log "handing off to separate.sh: $WAV_PATH"
  if [[ -x "$SEPARATE_SH" ]]; then
    # Run separate.sh synchronously. Backgrounding via '&' would be killed
    # when this oneshot systemd service exits (default KillMode=control-group).
    # Total time per cycle (~5 min) fits comfortably within the hourly timer.
    if "$SEPARATE_SH" "$WAV_PATH"; then
      log "separate.sh completed successfully"
    else
      log "separate.sh exited non-zero (rc=$?); see logs/separate/"
    fi
  else
    log "separate.sh not executable or missing: $SEPARATE_SH"
  fi
done <<<"$NEW_FILES"

log "=== auto_generate done ==="
