#!/usr/bin/env bash
# Install the ACE-Step auto-sampling systemd user units on this host.
#
# What it does:
#   1. Resolves PROJECT_ROOT to the absolute path of this checkout.
#   2. Builds EXTRA_PATH from the directories of `uv`, `gws`, `demucs` and
#      `trash-put` so the service can resolve them regardless of where
#      the user installed each tool.
#   3. Substitutes @PROJECT_ROOT@ and @EXTRA_PATH@ into the .service
#      template and writes it (with the timer) into ~/.config/systemd/user/.
#   4. Runs `systemctl --user daemon-reload`.
#   5. By default starts and enables the timer. Skip with --no-enable.
#
# Usage:
#   ./systemd/install.sh             # install + enable timer
#   ./systemd/install.sh --no-enable # install but leave timer disabled
#   ./systemd/install.sh --uninstall # disable + remove the units
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_NAME="ace-auto-generate.service"
TIMER_NAME="ace-auto-generate.timer"

case "${1:-}" in
  --uninstall)
    systemctl --user disable --now "$TIMER_NAME" 2>/dev/null || true
    rm -f "$UNIT_DIR/$SERVICE_NAME" "$UNIT_DIR/$TIMER_NAME"
    systemctl --user daemon-reload
    echo "Uninstalled $SERVICE_NAME and $TIMER_NAME."
    exit 0
    ;;
esac

ENABLE_TIMER=1
[[ "${1:-}" == "--no-enable" ]] && ENABLE_TIMER=0

# Collect directories of the tools the service needs to resolve. Skip
# any that aren't installed so install can still proceed; the user can
# fix PATH later by re-running this script.
declare -A SEEN
EXTRA_DIRS=()
for cmd in uv gws demucs trash-put; do
  p="$(command -v "$cmd" 2>/dev/null || true)"
  if [[ -z "$p" ]]; then
    echo "WARN: $cmd not found on PATH; service may fail until it is installed." >&2
    continue
  fi
  d="$(dirname "$p")"
  # Skip system dirs already covered by the default PATH tail.
  case "$d" in
    /usr/bin|/bin|/usr/sbin|/sbin|/usr/local/bin|/usr/local/sbin) continue ;;
  esac
  if [[ -z "${SEEN[$d]:-}" ]]; then
    SEEN[$d]=1
    EXTRA_DIRS+=("$d")
  fi
done
EXTRA_PATH="$(IFS=:; echo "${EXTRA_DIRS[*]:-}")"
[[ -z "$EXTRA_PATH" ]] && EXTRA_PATH="$HOME/.local/bin"

mkdir -p "$UNIT_DIR"

# Substitute into the service template.
sed \
  -e "s|@PROJECT_ROOT@|$PROJECT_ROOT|g" \
  -e "s|@EXTRA_PATH@|$EXTRA_PATH|g" \
  "$SCRIPT_DIR/$SERVICE_NAME.template" \
  > "$UNIT_DIR/$SERVICE_NAME"

# Timer has no substitutions; copy as-is.
cp "$SCRIPT_DIR/$TIMER_NAME" "$UNIT_DIR/$TIMER_NAME"

systemctl --user daemon-reload

echo "Installed:"
echo "  $UNIT_DIR/$SERVICE_NAME"
echo "  $UNIT_DIR/$TIMER_NAME"
echo "  PROJECT_ROOT = $PROJECT_ROOT"
echo "  EXTRA_PATH   = $EXTRA_PATH"

if [[ $ENABLE_TIMER -eq 1 ]]; then
  systemctl --user enable --now "$TIMER_NAME"
  echo "Timer enabled. Next run:"
  systemctl --user list-timers "$TIMER_NAME" --no-pager 2>&1 | tail -2
else
  echo "Timer NOT enabled (--no-enable). To enable manually:"
  echo "  systemctl --user enable --now $TIMER_NAME"
fi

# WSL2 reminder: lingering must be on so the timer fires even when the
# user isn't logged in graphically. Check current state and instruct.
if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
  echo ""
  echo "NOTE: User lingering appears to be off. To survive WSL session"
  echo "      ends, enable it once with:"
  echo "      sudo loginctl enable-linger $USER"
fi
