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

@test "window is closed with no transcripts" {
  run "$BIN" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"closed"* ]]
}

@test "window is open after recent activity" {
  recent_activity
  run "$BIN" status
  [[ "$output" == *"OPEN"* ]]
}

# ---- the default must NOT skip ----------------------------------------------

@test "default pings even when a window is open (anchoring beats saving)" {
  recent_activity
  run "$BIN" test
  [ "$status" -eq 0 ]
  [[ "$output" == *"would run:"* ]]
  [[ "$output" != *"skip"* ]]
}

@test "status reports skip-if-active off by default" {
  run "$BIN" status
  [[ "$output" == *"skip-if-active: no"* ]]
}

@test "SKIP_IF_ACTIVE=1 opts back into skipping" {
  recent_activity
  echo 'SKIP_IF_ACTIVE=1' >>"$XDG_CONFIG_HOME/claude-keepalive/config"
  run "$BIN" test
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
}

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

@test "even 5h spacing passes the anchoring check" {
  . "$REPO/lib/backend.sh"
  run hours_check_spacing "6,11,16,21" 5
  [ "$status" -eq 0 ]
}

@test "uneven spacing warns but does not fail hard" {
  . "$REPO/lib/backend.sh"
  run hours_check_spacing "6,10,14" 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"not stay anchored"* ]]
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

@test "config example ships the tunables uncommented" {
  grep -qE '^HOURS=' "$REPO/config/config.example"
  grep -qE '^SKIP_IF_ACTIVE=0' "$REPO/config/config.example"
}

@test "config example documents every option" {
  for key in CLAUDE_BIN MODEL PROMPT SKIP_IF_ACTIVE WINDOW_HOURS HOURS \
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
