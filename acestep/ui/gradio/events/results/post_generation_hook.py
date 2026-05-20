"""Post-generation external hook runner.

After a final audio file is written to disk, optionally invoke an external
script (e.g. stem separation + cloud upload) so the UI doesn't block.

The hook script path is read from the ``ACESTEP_POST_HOOK`` environment
variable. When unset, ``run_post_generation_hook`` is a no-op so this
adds zero overhead unless explicitly enabled.

Task types that don't produce a complete musical piece (``extract``,
``lego``) are skipped — their outputs aren't useful inputs to stem
separators.

The hook subprocess is launched **detached and non-blocking**: failures
are logged but never propagated to the UI, and the caller returns
immediately.
"""
from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path
from typing import Any

from loguru import logger


_HOOK_ENV_VAR = "ACESTEP_POST_HOOK"
_SKIP_TASK_TYPES = {"extract", "lego"}


def _hook_script_path() -> str | None:
    raw = os.environ.get(_HOOK_ENV_VAR, "").strip()
    if not raw:
        return None
    path = Path(raw).expanduser()
    if not path.is_file():
        logger.warning(
            f"{_HOOK_ENV_VAR} points to non-existent file: {raw} — skipping hook"
        )
        return None
    if not os.access(path, os.X_OK):
        logger.warning(
            f"{_HOOK_ENV_VAR} script is not executable: {raw} — skipping hook"
        )
        return None
    return str(path)


def run_post_generation_hook(audio_path: str, audio_params: dict[str, Any]) -> None:
    """Fire-and-forget invocation of the external post-generation script.

    Args:
        audio_path: Absolute path to the finalized audio file on disk.
        audio_params: Generation parameters dict (used for task_type filtering).
    """
    script = _hook_script_path()
    if script is None:
        return

    task_type = str(audio_params.get("task_type", "")).strip().lower()
    if task_type in _SKIP_TASK_TYPES:
        logger.debug(f"post-hook: skipping task_type={task_type!r}")
        return

    if not audio_path or not Path(audio_path).is_file():
        logger.warning(f"post-hook: audio file missing, skipping: {audio_path!r}")
        return

    try:
        # Detach so UI returns immediately. stdout/stderr → /dev/null so
        # the child outlives the parent cleanly. The script is responsible
        # for its own logging.
        subprocess.Popen(
            [script, audio_path],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
        logger.info(
            f"post-hook: launched {shlex.quote(script)} for {audio_path}"
        )
    except Exception as exc:  # noqa: BLE001 — must not break UI
        logger.warning(f"post-hook: failed to launch {script}: {exc}")
