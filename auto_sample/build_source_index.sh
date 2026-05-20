#!/usr/bin/env bash
# Build a flat index of audio files under $ROOT for random source selection
# by auto_generate.sh.
#
# Args:
#   $1  ROOT  Defaults to $ACE_SOURCE_ROOT, or /mnt/d/music_extracted as a
#             last-resort fallback. Override per-host via env var or arg.
#   $2  INDEX Defaults to <script-dir>/source_index.txt so the script is
#             location-independent and can be cloned anywhere.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT="${1:-${ACE_SOURCE_ROOT:-/mnt/d/music_extracted}}"
INDEX="${2:-$SCRIPT_DIR/source_index.txt}"

if [[ ! -d "$ROOT" ]]; then
  echo "ERROR: source root not found: $ROOT" >&2
  exit 1
fi

# Match WAV/MP3/FLAC, exclude AppleDouble (._*) and macOS metadata.
find "$ROOT" \
  -type f \( -iname "*.wav" -o -iname "*.mp3" -o -iname "*.flac" \) \
  ! -name "._*" \
  ! -path "*/__MACOSX/*" \
  > "$INDEX"

count=$(wc -l < "$INDEX")
echo "Indexed $count files → $INDEX"
