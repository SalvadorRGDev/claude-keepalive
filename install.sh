#!/usr/bin/env bash
#
# claude-keepalive installer.
#
# Every path created and every system flag flipped is recorded in an install
# manifest. uninstall.sh reverts exactly that list and nothing else — it never
# deletes a shared directory by pattern.

set -euo pipefail

PROGRAM="claude-keepalive"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"

CONFIG_DIR="$XDG_CONFIG_HOME/$PROGRAM"
STATE_DIR="$XDG_STATE_HOME/$PROGRAM"
MANIFEST="$STATE_DIR/install-manifest"
UNIT_DIR="$XDG_CONFIG_HOME/systemd/user"
AGENT_DIR="$HOME/Library/LaunchAgents"

PREFIX="$HOME/.local"
HOURS="6,11,16,21"
BACKEND="auto"
DRY_RUN=0
ENABLE_LINGER=0

usage() {
  cat <<EOF
usage: ./install.sh [options]

  --hours "6,11,16,21"   Hours of day to ping (default: 6,11,16,21)
  --backend BACKEND      auto | systemd | launchd | cron (default: auto)
  --prefix DIR           Install root for the script (default: ~/.local)
  --enable-linger        Linux: keep the timer running with no session open.
                         Needs sudo/polkit. Off by default; without it the
                         timer only runs while you are logged in.
  --dry-run              Print every action without performing any of it
  -h, --help             This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --enable-linger) ENABLE_LINGER=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

BIN_DEST="$PREFIX/bin/$PROGRAM"

say()  { printf '  %s\n' "$*"; }
note() { printf '\n%s\n' "$*"; }

# Execute, or just describe, depending on --dry-run.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would: %s\n' "$*"
  else
    "$@"
  fi
}

# Append one reversible action to the manifest.
record() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\n' "$1" "$2" >>"$MANIFEST"
}

detect_backend() {
  case "$(uname -s)" in
    Darwin) printf 'launchd' ;;
    Linux)
      if command -v systemctl >/dev/null 2>&1 &&
        systemctl --user show-environment >/dev/null 2>&1; then
        printf 'systemd'
      elif command -v crontab >/dev/null 2>&1; then
        printf 'cron'
      else
        printf 'none'
      fi
      ;;
    *) command -v crontab >/dev/null 2>&1 && printf 'cron' || printf 'none' ;;
  esac
}

# "6,11" -> "06,11" (systemd OnCalendar wants zero-padded hours)
pad_hours() {
  local out="" h arr
  IFS=',' read -ra arr <<<"$1"
  for h in "${arr[@]}"; do
    h="${h// /}"
    printf -v h '%02d' "$((10#$h))"
    out="${out:+$out,}$h"
  done
  printf '%s' "$out"
}

launchd_entries() {
  local h arr
  IFS=',' read -ra arr <<<"$1"
  for h in "${arr[@]}"; do
    h="${h// /}"
    printf '    <dict><key>Hour</key><integer>%d</integer>' "$((10#$h))"
    printf '<key>Minute</key><integer>0</integer></dict>\n'
  done
}

# Render a template to a destination and record it.
render() {
  local src=$1 dest=$2
  shift 2
  local content
  content=$(cat "$src")
  while [ $# -gt 0 ]; do
    content="${content//$1/$2}"
    shift 2
  done
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would write: %s\n' "$dest"
  else
    mkdir -p "$(dirname "$dest")"
    printf '%s\n' "$content" >"$dest"
    record file "$dest"
  fi
}

# ---- preflight --------------------------------------------------------------

printf '%s installer\n\n' "$PROGRAM"

[ "$BACKEND" = "auto" ] && BACKEND=$(detect_backend)
[ "$BACKEND" = "none" ] &&
  { printf 'error: no scheduler found (systemd, launchd or cron)\n' >&2; exit 1; }

if [ -e "$MANIFEST" ] && [ "$DRY_RUN" -eq 0 ]; then
  printf 'error: already installed (manifest at %s)\n' "$MANIFEST" >&2
  printf 'run ./uninstall.sh first, then install again.\n' >&2
  exit 1
fi

if ! "$SRC_DIR/bin/$PROGRAM" version >/dev/null 2>&1; then
  printf 'error: %s/bin/%s is not runnable\n' "$SRC_DIR" "$PROGRAM" >&2
  exit 1
fi

say "backend : $BACKEND"
say "hours   : $HOURS"
say "script  : $BIN_DEST"
[ "$DRY_RUN" -eq 1 ] && note "DRY RUN — nothing below is actually performed."

# ---- 1. the script ----------------------------------------------------------

note "1. installing the script"
run mkdir -p "$PREFIX/bin"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  would: install -m 0755 %s/bin/%s %s\n' "$SRC_DIR" "$PROGRAM" "$BIN_DEST"
else
  install -m 0755 "$SRC_DIR/bin/$PROGRAM" "$BIN_DEST"
  record file "$BIN_DEST"
  record backend "$BACKEND"
fi

# ---- 2. config --------------------------------------------------------------

note "2. installing default config"
if [ -e "$CONFIG_DIR/config" ]; then
  # We did not create it, so it is not ours to delete on a plain uninstall —
  # but --purge means "remove my config", so record that it exists.
  record config-kept "$CONFIG_DIR/config"
  say "kept existing $CONFIG_DIR/config"
elif [ "$DRY_RUN" -eq 1 ]; then
  printf '  would write: %s/config\n' "$CONFIG_DIR"
else
  mkdir -p "$CONFIG_DIR"
  cp "$SRC_DIR/config/config.example" "$CONFIG_DIR/config"
  record config "$CONFIG_DIR/config"
  record dir "$CONFIG_DIR"
  say "wrote $CONFIG_DIR/config"
fi

# ---- 3. scheduler -----------------------------------------------------------

note "3. registering the schedule"
case "$BACKEND" in
  systemd)
    render "$SRC_DIR/share/systemd/$PROGRAM.service.in" "$UNIT_DIR/$PROGRAM.service" \
      "@BIN@" "$BIN_DEST"
    render "$SRC_DIR/share/systemd/$PROGRAM.timer.in" "$UNIT_DIR/$PROGRAM.timer" \
      "@ONCALENDAR@" "*-*-* $(pad_hours "$HOURS"):00:00"
    run systemctl --user daemon-reload
    run systemctl --user enable --now "$PROGRAM.timer"
    record unit "$PROGRAM.timer"
    say "enabled $PROGRAM.timer"

    if [ "$ENABLE_LINGER" -eq 1 ]; then
      if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
        say "linger already enabled — leaving it alone"
      else
        run loginctl enable-linger "$USER"
        record linger "enabled-by-us"
        say "enabled linger (uninstall will turn it back off)"
      fi
    else
      say "linger NOT enabled — pass --enable-linger to run without a session"
    fi
    ;;

  launchd)
    render "$SRC_DIR/share/launchd/$PROGRAM.plist.in" "$AGENT_DIR/$PROGRAM.plist" \
      "@BIN@" "$BIN_DEST" \
      "@CALENDAR_ENTRIES@" "$(launchd_entries "$HOURS")"
    run launchctl unload "$AGENT_DIR/$PROGRAM.plist" 2>/dev/null || true
    run launchctl load "$AGENT_DIR/$PROGRAM.plist"
    record agent "$AGENT_DIR/$PROGRAM.plist"
    say "loaded $PROGRAM.plist"
    ;;

  cron)
    line="0 $HOURS * * * $BIN_DEST ping"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  would add crontab line: %s\n' "$line"
    else
      (crontab -l 2>/dev/null | grep -vF "$BIN_DEST" || true; printf '%s\n' "$line") |
        crontab -
      record cron "$BIN_DEST"
      say "added crontab line"
    fi
    ;;
esac

# ---- done -------------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  note "dry run complete — nothing was changed."
  exit 0
fi

record version "1.0.0"
record installed "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

note "installed."
cat <<EOF

  $PROGRAM status     see the window state and next scheduled run
  $PROGRAM test       dry-run a ping without sending one
  ./uninstall.sh      revert everything in the manifest

  manifest: $MANIFEST

Reminder: this does not grant extra quota. It only fixes your window
boundaries to predictable hours. See README.md.
EOF
