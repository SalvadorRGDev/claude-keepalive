#!/usr/bin/env bats
#
# Tests run against a throwaway XDG root so they never touch a real install.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO
  TMP="$(mktemp -d)"
  export TMP
  export XDG_CONFIG_HOME="$TMP/config"
  export XDG_STATE_HOME="$TMP/state"
  export HOME="$TMP"
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
  BIN="$REPO/bin/claude-keepalive"
  export BIN
}

teardown() {
  rm -rf "$TMP"
}

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

@test "status runs without an install" {
  run "$BIN" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"window"* ]]
}

@test "window is reported closed when there is no transcript" {
  run "$BIN" status
  [[ "$output" == *"closed"* ]]
}

@test "window is reported open after recent activity" {
  mkdir -p "$TMP/.claude/projects/demo"
  touch "$TMP/.claude/projects/demo/session.jsonl"
  run "$BIN" status
  [[ "$output" == *"OPEN"* ]]
}

@test "test skips the ping when a window is already open" {
  mkdir -p "$TMP/.claude/projects/demo"
  touch "$TMP/.claude/projects/demo/session.jsonl"
  run "$BIN" test
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
}

@test "test never actually runs claude" {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/claude" <<'FAKE'
#!/bin/sh
echo "THE REAL PING RAN" >&2
exit 1
FAKE
  chmod +x "$TMP/bin/claude"
  mkdir -p "$XDG_CONFIG_HOME/claude-keepalive"
  echo "CLAUDE_BIN=\"$TMP/bin/claude\"" >"$XDG_CONFIG_HOME/claude-keepalive/config"

  run "$BIN" test
  [ "$status" -eq 0 ]
  [[ "$output" != *"THE REAL PING RAN"* ]]
  [[ "$output" == *"would run:"* ]]
}

@test "dry-run install changes nothing" {
  run "$REPO/install.sh" --dry-run --backend cron
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [ ! -e "$XDG_STATE_HOME/claude-keepalive/install-manifest" ]
  [ ! -e "$TMP/.local/bin/claude-keepalive" ]
}

@test "uninstall refuses to guess without a manifest" {
  run "$REPO/uninstall.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no manifest"* ]]
}

@test "config example covers every documented option" {
  for key in CLAUDE_BIN MODEL PROMPT SKIP_IF_ACTIVE WINDOW_HOURS \
    MAX_BUDGET_USD PING_TIMEOUT LOG_MAX_LINES; do
    grep -q "$key" "$REPO/config/config.example"
  done
}
