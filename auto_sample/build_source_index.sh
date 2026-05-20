#!/usr/bin/env bash
# Build a flat index of audio files under /mnt/d/music_extracted/ for random
# source selection by auto_generate.sh.
set -euo pipefail

ROOT="${1:-/mnt/d/music_extracted}"
INDEX="${2:-/home/sarai/work/ACE-Step-1.5/auto_sample/source_index.txt}"

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
