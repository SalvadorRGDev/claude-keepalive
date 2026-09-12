#!/usr/bin/env bash
#
# claude-keepalive uninstaller.
#
# Reads the install manifest and reverts exactly what install.sh did — nothing
# more. It never deletes a directory by pattern, because the directories it
# touches (~/.config/systemd/user, ~/.local/bin) are shared with the rest of
# your system.

set -euo pipefail

PROGRAM="claude-keepalive"

: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"

CONFIG_DIR="$XDG_CONFIG_HOME/$PROGRAM"
STATE_DIR="$XDG_STATE_HOME/$PROGRAM"
MANIFEST="$STATE_DIR/install-manifest"

PURGE=0
DRY_RUN=0

usage() {
  cat <<EOF
usage: ./uninstall.sh [options]

  --purge     Also delete the config file and the log (kept by default)
  --dry-run   Print every action without performing any of it
  -h, --help  This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

say() { printf '  %s\n' "$*"; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would: %s\n' "$*"
  else
    "$@"
  fi
}

printf '%s uninstaller\n\n' "$PROGRAM"

if [ ! -r "$MANIFEST" ]; then
  printf 'no manifest at %s — nothing recorded as installed.\n' "$MANIFEST" >&2
  printf 'if you installed by hand, remove your units/crontab entry yourself.\n' >&2
  exit 1
fi

[ "$DRY_RUN" -eq 1 ] && printf 'DRY RUN — nothing below is actually performed.\n\n'

field() { awk -v k="$1" -F'\t' '$1==k{print $2}' "$MANIFEST"; }

# ---- 1. stop the scheduler first, so nothing fires mid-removal --------------

printf '1. stopping the schedule\n'

while IFS=$'\t' read -r kind value; do
  case "$kind" in
    unit)
      run systemctl --user disable --now "$value" || true
      say "disabled $value"
      ;;
    agent)
      run launchctl unload "$value" || true
      say "unloaded $value"
      ;;
    cron)
      if [ "$DRY_RUN" -eq 1 ]; then
        printf '  would: remove crontab lines containing %s\n' "$value"
      else
        crontab -l 2>/dev/null | grep -vF "$value" | crontab - || true
        say "removed crontab line"
      fi
      ;;
  esac
done <"$MANIFEST"

# ---- 2. remove the files we created -----------------------------------------

printf '\n2. removing installed files\n'

while IFS=$'\t' read -r kind value; do
  case "$kind" in
    file | agent)
      if [ -e "$value" ]; then
        run rm -f "$value"
        say "removed $value"
      else
        say "already gone: $value"
      fi
      ;;
    config | config-kept)
      if [ "$PURGE" -eq 1 ]; then
        [ -e "$value" ] && { run rm -f "$value"; say "purged $value"; }
      else
        say "kept $value (use --purge to delete)"
      fi
      ;;
  esac
done <"$MANIFEST"

if [ "$(field backend)" = "systemd" ]; then
  run systemctl --user daemon-reload
  say "reloaded systemd user manager"
fi

# ---- 3. revert the linger flag, but only if we were the ones who set it -----

printf '\n3. system flags\n'
if [ "$(field linger)" = "enabled-by-us" ]; then
  run loginctl disable-linger "$USER" || true
  say "disabled linger (we enabled it at install time)"
else
  say "linger untouched (we never enabled it)"
fi

# ---- 4. directories, only if empty ------------------------------------------

printf '\n4. directories\n'
while IFS=$'\t' read -r kind value; do
  [ "$kind" = "dir" ] || continue
  if [ -d "$value" ] && [ -z "$(ls -A "$value" 2>/dev/null)" ]; then
    run rmdir "$value"
    say "removed empty $value"
  elif [ -d "$value" ]; then
    say "kept non-empty $value"
  fi
done <"$MANIFEST"

# ---- 5. our own state -------------------------------------------------------

printf '\n5. state\n'
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  would: rm %s\n' "$MANIFEST"
  if [ "$PURGE" -eq 1 ]; then
    printf '  would: rm -rf %s\n' "$CONFIG_DIR"
    printf '  would: rm -rf %s\n' "$STATE_DIR"
  fi
else
  # The manifest always goes: it describes an install that no longer exists.
  rm -f "$MANIFEST"
  if [ "$PURGE" -eq 1 ]; then
    # These two directories are exclusively ours, so removing them whole is
    # safe — unlike ~/.config/systemd/user, which we only ever touch by name.
    [ -d "$CONFIG_DIR" ] && { rm -rf "$CONFIG_DIR"; say "purged $CONFIG_DIR"; }
    rm -rf "$STATE_DIR"
    say "purged $STATE_DIR"
  else
    say "removed manifest; kept log at $STATE_DIR/log (use --purge to delete)"
    if rmdir "$STATE_DIR" 2>/dev/null; then
      say "removed empty $STATE_DIR"
    fi
  fi
fi

printf '\ndone.\n'
[ "$PURGE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && cat <<EOF

Config and log were kept. Re-run with --purge to remove them too.
The repo folder itself is not touched — delete it by hand when you are done.
EOF
exit 0
