#!/usr/bin/env python3
"""Pick a random Caption/Lyrics/params combo and emit a TOML file for cli.py.

Usage:
    pick_caption.py --mode auto --output /path/to/run.toml --save-dir /path/to/output
    pick_caption.py --mode cover --output ... --save-dir ... --src-audio /path/to/ref.wav
    pick_caption.py --mode t2m   --output ... --save-dir ...

The script:
  1. Loads templates.json
  2. Picks a task mode (cover/t2m) and a genre matching that mode
  3. Composes a Caption from genre + random mood + texture + negatives
  4. For t2m: picks a vocal_styles entry and a Lyrics block
  5. For cover: picks audio_cover_strength from genre range; src_audio passed in
  6. Writes a TOML file consumable by cli.py
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

TEMPLATES_PATH = Path(__file__).with_name("templates.json")


def load_templates() -> dict:
    with open(TEMPLATES_PATH, encoding="utf-8") as f:
        return json.load(f)


def pick_genre(templates: dict, mode: str) -> dict:
    candidates = [g for g in templates["genres"] if g["use"] in (mode, "both")]
    if not candidates:
        raise SystemExit(f"No genres for mode={mode}")
    return random.choice(candidates)


def compose_caption(genre: dict, mood: str, texture: str, *, instrumental: bool,
                    vocal_style: str | None) -> str:
    parts: list[str] = []
    parts.extend(genre.get("extra_tags", []))
    parts.append(mood)
    parts.extend(genre.get("instruments", []))
    parts.append(texture)
    if instrumental:
        parts.append("fully instrumental")
        parts.append("no vocals")
    else:
        if vocal_style:
            parts.append(vocal_style)
        parts.append("vocal-forward mix")
    parts.extend(genre.get("negatives", []))
    seen: set[str] = set()
    out: list[str] = []
    for p in parts:
        key = p.strip().lower()
        if key and key not in seen:
            seen.add(key)
            out.append(p.strip())
    return ", ".join(out)


def pick_lyrics_block(templates: dict) -> str:
    block = random.choice(templates["vocal_lyrics_pool"])
    return (
        f"[Intro]\n{block['intro']}\n\n"
        f"[Verse]\n{block['verse']}\n\n"
        f"[Pre-Chorus]\n{block['pre_chorus']}\n\n"
        f"[Chorus]\n{block['chorus']}\n\n"
        f"[Bridge]\n{block['bridge']}\n\n"
        f"[Outro]\n{block['outro']}\n"
    )


def toml_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def build_toml(*, task_type: str, caption: str, lyrics: str | None,
               instrumental: bool, src_audio: str | None,
               audio_cover_strength: float | None, duration: float,
               bpm: int, keyscale: str, seed: int, save_dir: str,
               genre_name: str, mood: str) -> str:
    lines: list[str] = []
    lines.append(f"# Auto-generated for {genre_name} ({mood})")
    lines.append(f'task_type = "{task_type}"')
    if src_audio:
        lines.append(f'src_audio = "{toml_escape(src_audio)}"')
    if audio_cover_strength is not None:
        lines.append(f"audio_cover_strength = {audio_cover_strength:.2f}")
    lines.append(f'caption = "{toml_escape(caption)}"')
    lines.append(f"instrumental = {'true' if instrumental else 'false'}")
    if lyrics is None:
        lines.append('lyrics = "[Instrumental]"')
    else:
        lines.append('lyrics = """')
        lines.append(lyrics.rstrip())
        lines.append('"""')
    lines.append(f"duration = {duration}")
    lines.append(f"bpm = {bpm}")
    lines.append(f'keyscale = "{keyscale}"')
    lines.append(f"seed = {seed}")
    lines.append("batch_size = 1")
    lines.append("shift = 2.5")
    lines.append("lm_temperature = 0.7")
    lines.append("use_cot_caption = true")
    lines.append("use_cot_metas = true")
    lines.append('infer_method = "ode"')
    if task_type == "text2music":
        lines.append("thinking = true")
        lines.append("use_cot_lyrics = false")
    lines.append(f'save_dir = "{toml_escape(save_dir)}"')
    lines.append('audio_format = "wav"')
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["auto", "cover", "t2m"], default="auto")
    ap.add_argument("--output", required=True, help="Path to write TOML")
    ap.add_argument("--save-dir", required=True, help="Directory for generated WAV")
    ap.add_argument("--src-audio", help="Required for cover mode")
    ap.add_argument("--duration", type=float, default=110.0)
    ap.add_argument("--seed", type=int, default=None)
    args = ap.parse_args()

    templates = load_templates()
    if args.mode == "auto":
        modes = templates["task_modes"]
        mode = random.choices([m["mode"] for m in modes],
                              weights=[m["weight"] for m in modes], k=1)[0]
    else:
        mode = args.mode

    if mode == "cover" and not args.src_audio:
        print("ERROR: --src-audio is required for cover mode", file=sys.stderr)
        return 2

    genre = pick_genre(templates, mode)
    mood = random.choice(templates["moods"])
    texture = random.choice(templates["production_textures"])

    if mode == "cover":
        instrumental = not bool(genre.get("vocal_styles")) or random.random() < 0.5
        vocal_style = (None if instrumental
                       else random.choice(genre["vocal_styles"]))
        cs_low, cs_high = next(m["cover_strength_range"]
                               for m in templates["task_modes"] if m["mode"] == "cover")
        audio_cover_strength = round(random.uniform(cs_low, cs_high), 2)
        task_type = "cover"
        src_audio = args.src_audio
        lyrics = None if instrumental else pick_lyrics_block(templates)
    else:
        instrumental = False
        vocals_avail = genre.get("vocal_styles") or ["soulful female vocal"]
        vocal_style = random.choice(vocals_avail)
        audio_cover_strength = None
        task_type = "text2music"
        src_audio = None
        lyrics = pick_lyrics_block(templates)

    caption = compose_caption(genre, mood, texture,
                              instrumental=instrumental, vocal_style=vocal_style)
    bpm_lo, bpm_hi = genre["bpm_range"]
    bpm = random.randint(bpm_lo, bpm_hi)
    keyscale = random.choice(genre["keys"])
    seed = args.seed if args.seed is not None else random.randint(1, 2_000_000_000)

    toml_text = build_toml(
        task_type=task_type,
        caption=caption,
        lyrics=lyrics,
        instrumental=instrumental,
        src_audio=src_audio,
        audio_cover_strength=audio_cover_strength,
        duration=args.duration,
        bpm=bpm,
        keyscale=keyscale,
        seed=seed,
        save_dir=args.save_dir,
        genre_name=genre["name"],
        mood=mood,
    )

    Path(args.output).write_text(toml_text, encoding="utf-8")
    print(f"mode={mode} genre={genre['name']} bpm={bpm} key={keyscale} "
          f"strength={audio_cover_strength} seed={seed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
