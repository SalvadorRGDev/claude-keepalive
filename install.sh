#!/usr/bin/env bash
#
# claude-keepalive installer.
#
# Every path created and every system flag flipped is recorded in an install
# manifest. uninstall.sh reverts exactly that list and nothing else — it never
# removes a shared directory by pattern.

set -euo pipefail

PROGRAM="claude-keepalive"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"

CONFIG_DIR="$XDG_CONFIG_HOME/$PROGRAM"
STATE_DIR="$XDG_STATE_HOME/$PROGRAM"
MANIFEST="$STATE_DIR/install-manifest"

PREFIX="$HOME/.local"
HOURS="6,11,16,21"
WINDOW_HOURS=5
BACKEND="auto"
DRY_RUN=0
ENABLE_LINGER=0

usage() {
  cat <<EOF
usage: ./install.sh [options]

  --hours "6,11,16,21"   Hours of day to ping (default: 6,11,16,21).
                         Keep them WINDOW_HOURS apart so windows stay anchored.
                         Afterwards use \`$PROGRAM schedule <hours>\` — no
                         reinstall needed to change them.
  --backend BACKEND      auto | systemd | launchd | cron (default: auto)
  --prefix DIR           Install root (default: ~/.local)
  --enable-linger        Linux: keep the timer running with no session open.
                         Needs sudo/polkit. Off by default; without it the timer
                         only fires while you are logged in.
  --dry-run              Print every action, perform none
  -h, --help             This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hours | --hour) HOURS="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --enable-linger) ENABLE_LINGER=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

BIN_DEST="$PREFIX/bin/$PROGRAM"
LIB_DEST="$PREFIX/lib/$PROGRAM/backend.sh"

# shellcheck source=lib/backend.sh
. "$SRC_DIR/lib/backend.sh"

say() { printf '  %s\n' "$*"; }
note() { printf '\n%s\n' "$*"; }

# ---- backend-library hooks: make it dry-run aware and manifest-aware ---------

bk_say() { say "$@"; }

bk_run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would: %s\n' "$*"
  else
    "$@"
  fi
}

bk_write() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would write: %s\n' "$1"
  else
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" >"$1"
  fi
}

bk_record() { record "$1" "$2"; }

record() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\n' "$1" "$2" >>"$MANIFEST"
}

# ---- preflight --------------------------------------------------------------

printf '%s installer\n\n' "$PROGRAM"

HOURS=$(hours_normalize "$HOURS") || { printf 'error: bad --hours\n' >&2; exit 1; }

[ "$BACKEND" = "auto" ] && BACKEND=$(backend_detect)
if [ "$BACKEND" = "none" ]; then
  printf 'error: no scheduler found (systemd, launchd or cron)\n' >&2
  exit 1
fi

if [ -e "$MANIFEST" ] && [ "$DRY_RUN" -eq 0 ]; then
  printf 'error: already installed (manifest at %s)\n' "$MANIFEST" >&2
  printf 'to change the hours:  %s schedule <hours>\n' "$PROGRAM" >&2
  printf 'to reinstall:         ./uninstall.sh && ./install.sh\n' >&2
  exit 1
fi

if ! "$SRC_DIR/bin/$PROGRAM" version >/dev/null 2>&1; then
  printf 'error: %s/bin/%s is not runnable\n' "$SRC_DIR" "$PROGRAM" >&2
  exit 1
fi

say "backend : $BACKEND"
say "hours   : $HOURS"
say "script  : $BIN_DEST"
hours_advise "$HOURS" "$WINDOW_HOURS" || true
[ "$DRY_RUN" -eq 1 ] && note "DRY RUN — nothing below is actually performed."

# ---- 1. script and library --------------------------------------------------

note "1. installing the script"
bk_run mkdir -p "$PREFIX/bin" "$PREFIX/lib/$PROGRAM"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  would: install -m 0755 %s -> %s\n' "bin/$PROGRAM" "$BIN_DEST"
  printf '  would: install -m 0644 %s -> %s\n' "lib/backend.sh" "$LIB_DEST"
else
  install -m 0755 "$SRC_DIR/bin/$PROGRAM" "$BIN_DEST"
  record file "$BIN_DEST"
  install -m 0644 "$SRC_DIR/lib/backend.sh" "$LIB_DEST"
  record file "$LIB_DEST"
  record dir "$PREFIX/lib/$PROGRAM"
  record backend "$BACKEND"
  say "installed $BIN_DEST"
  say "installed $LIB_DEST"
fi

# ---- 2. config --------------------------------------------------------------

note "2. installing config"
if [ -e "$CONFIG_DIR/config" ]; then
  # Not ours to delete on a plain uninstall, but --purge means "remove my
  # config", so record that it is there.
  record config-kept "$CONFIG_DIR/config"
  say "kept existing $CONFIG_DIR/config"
  say "run '$PROGRAM schedule $HOURS' if its HOURS differ"
elif [ "$DRY_RUN" -eq 1 ]; then
  printf '  would write: %s/config (HOURS="%s")\n' "$CONFIG_DIR" "$HOURS"
else
  mkdir -p "$CONFIG_DIR"
  sed -E "s|^HOURS=.*|HOURS=\"$HOURS\"|" "$SRC_DIR/config/config.example" \
    >"$CONFIG_DIR/config"
  record config "$CONFIG_DIR/config"
  record dir "$CONFIG_DIR"
  say "wrote $CONFIG_DIR/config"
fi

# ---- 3. schedule ------------------------------------------------------------

note "3. registering the schedule"
backend_apply "$BACKEND" "$BIN_DEST" "$HOURS"

if [ "$BACKEND" = "systemd" ]; then
  if [ "$ENABLE_LINGER" -eq 1 ]; then
    if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" = "yes" ]; then
      say "linger already enabled — leaving it alone"
    else
      bk_run loginctl enable-linger "$USER"
      record linger "enabled-by-us"
      say "enabled linger (uninstall will turn it back off)"
    fi
  else
    say "linger NOT enabled — pings only fire while you are logged in"
    say "re-run with --enable-linger to change that"
  fi
fi

# ---- done -------------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  note "dry run complete — nothing was changed."
  exit 0
fi

record version "2.0.0"
record installed "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

note "installed."
cat <<EOF

  $PROGRAM status            window state and next scheduled run
  $PROGRAM test              dry-run a ping without sending one
  $PROGRAM schedule 7,12,17,22   change the hours, no reinstall
  ./uninstall.sh             revert everything in the manifest

  manifest: $MANIFEST

Reminder: this grants no extra quota. It anchors your window boundaries to
fixed hours so you always know when the next reset lands. See README.md.
EOF
