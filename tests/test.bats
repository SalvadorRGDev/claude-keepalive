#!/usr/bin/env bats
#
# Tests run against a throwaway HOME/XDG root, so they never touch a real
# install and never invoke the real claude CLI.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export REPO TMP
  export HOME="$TMP"
  export XDG_CONFIG_HOME="$TMP/config"
  export XDG_STATE_HOME="$TMP/state"
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$TMP/bin"
  BIN="$REPO/bin/claude-keepalive"
  export BIN

  # A claude that screams if it is ever actually executed.
  cat >"$TMP/bin/claude" <<'FAKE'
#!/bin/sh
echo "THE REAL PING RAN" >&2
exit 0
FAKE
  chmod +x "$TMP/bin/claude"
  mkdir -p "$XDG_CONFIG_HOME/claude-keepalive"
  printf 'CLAUDE_BIN="%s/bin/claude"\n' "$TMP" \
    >"$XDG_CONFIG_HOME/claude-keepalive/config"
}

teardown() { rm -rf "$TMP"; }

recent_activity() {
  mkdir -p "$TMP/.claude/projects/demo"
  touch "$TMP/.claude/projects/demo/s.jsonl"
}

# ---- basics -----------------------------------------------------------------

@test "version prints the program name" {
  run "$BIN" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-keepalive"* ]]
}

@test "help is shown with no arguments" {
  run "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "unknown command fails" {
  run "$BIN" definitely-not-a-command
  [ "$status" -ne 0 ]
}

# ---- window detection -------------------------------------------------------

@test "no transcripts means no activity to report" {
  run "$BIN" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"last activity : none found"* ]]
}

@test "activity older than a window reports no window open" {
  mkdir -p "$TMP/.claude/projects/demo"
  touch -d "6 hours ago" "$TMP/.claude/projects/demo/s.jsonl"
  run "$BIN" status
  [[ "$output" == *"no window open"* ]]
}

# ---- the default must NOT skip ----------------------------------------------

@test "test never actually runs claude" {
  run "$BIN" test
  [ "$status" -eq 0 ]
  [[ "$output" != *"THE REAL PING RAN"* ]]
}

# ---- hour parsing -----------------------------------------------------------

@test "hours are normalised and sorted" {
  # shellcheck disable=SC1091
  . "$REPO/lib/backend.sh"
  [ "$(hours_normalize '21, 6,11,16')" = "6,11,16,21" ]
  [ "$(hours_normalize '6')" = "6" ]
}

@test "hours are zero-padded for systemd" {
  . "$REPO/lib/backend.sh"
  [ "$(hours_pad '6,11,16,21')" = "06,11,16,21" ]
}

@test "bad hours are rejected" {
  . "$REPO/lib/backend.sh"
  run hours_normalize "25"
  [ "$status" -ne 0 ]
  run hours_normalize "abc"
  [ "$status" -ne 0 ]
}

@test "hours a whole number of windows apart are silently fine" {
  . "$REPO/lib/backend.sh"
  for h in "8,13" "6,11,16" "6,11,16,21" "8,13,18"; do
    run hours_advise "$h" 5
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "a gap of two whole windows also lands on a boundary" {
  . "$REPO/lib/backend.sh"
  # 06:00 -> 16:00 is 10h, exactly two windows, so 16:00 is a boundary of the
  # chain 06-11, 11-16. No advice needed.
  run hours_advise "6,16" 5
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hours off the boundaries are noted as conditional, not rejected" {
  . "$REPO/lib/backend.sh"
  run hours_advise "6,18" 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"genuinely away"* ]]
  [[ "$output" == *"18:00 does not sit"* ]]

  # The schedule that reads like three sessions but delivers two.
  run hours_advise "6,14,22" 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"14:00, 22:00 do not sit"* ]]
}

@test "gaps narrower than a window are flagged as wasted pings" {
  . "$REPO/lib/backend.sh"
  run hours_advise "6,10,14" 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"opens"* ]]
  [[ "$output" == *"nothing, ever"* ]]
  [[ "$output" == *"move it to 11:00"* ]]
}

# ---- generated units --------------------------------------------------------

@test "generated timer carries the requested hours" {
  . "$REPO/lib/backend.sh"
  run bk_systemd_timer "7,12,17,22"
  [[ "$output" == *"OnCalendar=*-*-* 07,12,17,22:00:00"* ]]
}

@test "generated service logs nowhere, so uninstall leaves no journal residue" {
  . "$REPO/lib/backend.sh"
  run bk_systemd_service "/usr/bin/claude-keepalive"
  [[ "$output" == *"StandardOutput=null"* ]]
  [[ "$output" == *"StandardError=null"* ]]
}

@test "generated plist carries one entry per hour" {
  . "$REPO/lib/backend.sh"
  run bk_launchd_plist "/usr/bin/claude-keepalive" "6,11,16,21"
  [ "$(printf '%s\n' "$output" | grep -c '<key>Hour</key>')" -eq 4 ]
}

# ---- schedule ---------------------------------------------------------------

@test "schedule refuses when not installed" {
  run "$BIN" schedule 7,12,17,22
  [ "$status" -ne 0 ]
  [[ "$output" == *"not installed"* ]]
}

# ---- install / uninstall ----------------------------------------------------

@test "dry-run install changes nothing" {
  run "$REPO/install.sh" --dry-run --backend cron
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [ ! -e "$XDG_STATE_HOME/claude-keepalive/install-manifest" ]
  [ ! -e "$TMP/.local/bin/claude-keepalive" ]
}

@test "dry-run install rejects bad hours" {
  run "$REPO/install.sh" --dry-run --backend cron --hours "99"
  [ "$status" -ne 0 ]
}

@test "uninstall refuses to guess without a manifest" {
  run "$REPO/uninstall.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no manifest"* ]]
}

@test "config example ships HOURS uncommented" {
  grep -qE '^HOURS=' "$REPO/config/config.example"
}

@test "config example documents every option" {
  for key in CLAUDE_BIN MODEL PROMPT WINDOW_HOURS HOURS \
    MAX_BUDGET_USD PING_TIMEOUT LOG_MAX_LINES; do
    grep -q "$key" "$REPO/config/config.example"
  done
}

@test "an empty hour list is refused, not silently turned into midnight" {
  . "$REPO/lib/backend.sh"
  run bk_systemd_timer ""
  [ "$status" -ne 0 ]
  [[ "$output" != *"00:00:00"* ]]

  run bk_launchd_plist "/bin/true" ""
  [ "$status" -ne 0 ]
}

@test "pings are unconditional: recent activity does not skip" {
  recent_activity
  run "$BIN" test
  [ "$status" -eq 0 ]
  [[ "$output" == *"would run:"* ]]
  [[ "$output" != *"skip"* ]]
}

@test "status shows the next scheduled ping" {
  run "$BIN" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"next ping"* ]]
}

@test "status no longer claims to know when the window closes" {
  recent_activity
  run "$BIN" status
  [[ "$output" == *"a window is open"* ]]
  [[ "$output" != *"closes in"* ]]
}

@test "an obsolete SKIP_IF_ACTIVE in the config is called out, not ignored" {
  echo 'SKIP_IF_ACTIVE=1' >>"$XDG_CONFIG_HOME/claude-keepalive/config"
  run "$BIN" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed in 2.0.0"* ]]
}

@test "next ping is always in the future and within a day" {
  . "$REPO/bin/claude-keepalive" version >/dev/null 2>&1 || true
  run bash -c '. /dev/stdin <<<"$(sed -n "/^next_ping()/,/^}/p" '"$REPO"'/bin/claude-keepalive)"
    read -r h d <<<"$(next_ping 6,11,16,21)"
    [ "$d" -gt 0 ] && [ "$d" -le 86400 ] && echo "ok $h $d"'
  [ "$status" -eq 0 ]
  [[ "$output" == ok* ]]
}

@test "config example no longer ships SKIP_IF_ACTIVE as an option" {
  ! grep -qE '^SKIP_IF_ACTIVE=' "$REPO/config/config.example"
  ! grep -qE '^#SKIP_IF_ACTIVE=' "$REPO/config/config.example"
}

@test "the README documents only schedules the tool stays quiet about" {
  # Every hour list offered as a recommendation in the schedule examples block
  # must be one hours_advise does not warn about.
  . "$REPO/lib/backend.sh"
  while read -r h; do
    run hours_advise "$h" 5
    [ "$status" -eq 0 ]
  done < <(sed -n '/^claude-keepalive schedule [0-9]/s/^claude-keepalive schedule \([0-9,]*\).*/\1/p' \
    "$REPO/README.md" | sort -u)
}
