#!/usr/bin/env bash
# fix-dim-after-resume.sh — workaround for a KDE Plasma 6 bug (seen on 6.8.3):
# after waking from sleep, KWin keeps the "dim automatically" multiplier
# applied (e.g. 30%), so every screen stays dark even with brightness at 100%.
#
# Usage:
#   ./fix-dim-after-resume.sh             resets the dimming once, right now
#   ./fix-dim-after-resume.sh install     installs a systemd user service that
#                                         resets the dimming after every resume
#   ./fix-dim-after-resume.sh uninstall   removes the service (once the bug is
#                                         fixed upstream)
#   ./fix-dim-after-resume.sh status      shows the service and dimming state
#   ./fix-dim-after-resume.sh --help      shows this help
#   ./fix-dim-after-resume.sh watch       (used by the service) waits for logind
#                                         resume signals and resets the dimming
set -euo pipefail

NAME="fix-dim-after-resume"
BIN="$HOME/.local/bin/$NAME"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/$NAME.service"

# Seconds after resume to reset the dimming. More than one pass because
# PowerDevil/KWin may restore the dimmed state a few seconds after waking up.
DELAYS=(2 5 10)

# Prints the header comment (from "Usage:" to the first non-comment line).
usage() {
  sed -n '/^# Usage:/,/^[^#]/{/^#/s/^# \{0,1\}//p}' "$0"
}

# Prints the names of the connected and enabled outputs.
outputs() {
  kscreen-doctor -j | python3 -c '
import json, sys
for o in json.load(sys.stdin).get("outputs", []):
    if o.get("connected") and o.get("enabled"):
        print(o["name"])
'
}

reset_dimming() {
  local args=() out
  while read -r out; do
    [ -n "$out" ] && args+=("output.$out.dimming.100")
  done < <(outputs)
  if [ ${#args[@]} -eq 0 ]; then
    echo "No connected output found." >&2
    return 1
  fi
  kscreen-doctor "${args[@]}" >/dev/null
  echo "Dimming reset to 100% on: $(outputs | paste -sd' ')"
}

watch() {
  echo "Waiting for resume signals from logind..."
  # PrepareForSleep(false) is emitted when the system wakes up
  gdbus monitor --system --dest org.freedesktop.login1 \
      --object-path /org/freedesktop/login1 |
    while read -r line; do
      case "$line" in
        *PrepareForSleep*false*)
          echo "Resume detected."
          local prev=0 d
          for d in "${DELAYS[@]}"; do
            sleep $((d - prev)); prev=$d
            reset_dimming || true
          done
          ;;
      esac
    done
}

install() {
  for cmd in kscreen-doctor gdbus python3 systemctl; do
    command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 1; }
  done
  # Copies the script so the service doesn't depend on where this repo lives
  mkdir -p "$(dirname "$BIN")" "$UNIT_DIR"
  cp "$(readlink -f "$0")" "$BIN"
  chmod +x "$BIN"
  cat > "$UNIT" <<EOF
[Unit]
Description=Reset KDE screen dimming after resume (Plasma bug workaround)
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=$BIN watch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable "$NAME.service"
  systemctl --user restart "$NAME.service"   # picks up a reinstalled copy
  echo "Installed: $UNIT"
  echo "Logs: journalctl --user -u $NAME -f"
}

uninstall() {
  systemctl --user disable --now "$NAME.service" 2>/dev/null || true
  rm -f "$UNIT" "$BIN"
  systemctl --user daemon-reload
  echo "Removed $NAME."
}

status() {
  systemctl --user --no-pager status "$NAME.service" 2>/dev/null | head -5 ||
    echo "Service not installed."
  echo
  kscreen-doctor -o | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^Output|Brightness control'
}

case "${1:-}" in
  "")        reset_dimming ;;
  watch)     watch ;;
  install)   install ;;
  uninstall) uninstall ;;
  status)    status ;;
  -h|--help|help) usage ;;
  *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
esac
