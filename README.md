# claude-keepalive

Anchors your Claude usage windows to fixed hours, so you always know when the
next reset lands.

```
claude-keepalive status
```
```
claude-keepalive 1.1.0

claude binary : /usr/bin/claude
config        : ~/.config/claude-keepalive/config
model         : claude-haiku-4-5-20251001
hours         : 6,11,16,21
skip-if-active: no (pings unconditionally, keeps windows anchored)
window        : OPEN (last activity 0h42m ago, closes in 4h18m)
backend       : systemd
```

## What it does, and what it does not

**It grants no extra quota.** A Claude usage window starts with your first
message and runs for five hours. Pinging on a schedule does not extend a window
or raise its allowance, and the weekly cap above it still applies.

What it does is make your resets **predictable**. That matters more than it
sounds, because of how running out actually plays out: if you burn a window's
allowance in two hours, you wait for that window to close before you can send
anything again. Whether that wait ends at a time you know in advance, or at
whatever o'clock your first message happened to land, is the difference between
planning your day around it and being surprised by it.

### Why the hours are five apart

Pings spaced exactly `WINDOW_HOURS` apart form a chain: each ping fires at the
instant the window opened by the previous ping expires, so it opens the next one
immediately. Nothing drifts. With `6,11,16,21` your resets land at 11:00, 16:00
and 21:00, every day, whatever you did in between.

Break the spacing and you break the chain. `install.sh` and
`claude-keepalive schedule` both warn when consecutive hours are not
`WINDOW_HOURS` apart. An overnight gap (21:00 → 06:00) is fine and expected; a
daytime one is not.

### Why `SKIP_IF_ACTIVE` defaults to 0

The tool can detect that a window is already open — it reads the mtimes of your
transcripts in `~/.claude/projects` — and skip the ping to save a few tokens.
That is **off by default**, and the reasoning is worth spelling out because it is
easy to get backwards.

Skipping looks like free savings. It is not: a skipped ping is a broken link in
the chain. The next window then opens whenever you happen to send a message
rather than on the hour, and every reset after it inherits the drift.

The intuition that makes skipping look attractive — "a window that is already
half elapsed is worth less" — is false. The allowance is per window, not per
hour. You can spend all of a window's allowance in the thirty minutes it has
left, and still get a fresh window at the next boundary. A partly elapsed window
is not a partial allowance.

So the default is to ping unconditionally. Set `SKIP_IF_ACTIVE=1` only if you
would genuinely rather save four trivial Haiku pings a day than keep your reset
times predictable. The window detection still powers `status` either way.

### The honest caveat

Automating requests to manage usage limits sits in a gray area of Anthropic's
usage policy. This tool is deliberately minimal — one trivial prompt on the
cheapest model, with a hard spend ceiling — but decide for yourself whether you
want to run it.

## Install

```sh
git clone https://github.com/SalvadorRGDev/claude-keepalive
cd claude-keepalive
./install.sh --dry-run     # audit: prints every action, performs none
./install.sh               # do it
```

| Flag | Meaning |
|---|---|
| `--hours "6,11,16,21"` | Ping hours. Default `6,11,16,21`. |
| `--backend systemd\|launchd\|cron` | Scheduler. Auto-detected. |
| `--prefix DIR` | Install root. Default `~/.local`. |
| `--enable-linger` | Linux: keep the timer firing with no session open. Needs sudo. |
| `--dry-run` | Print every action, perform none. |

Backends are detected automatically: systemd user timers on Linux, launchd on
macOS, cron as a fallback.

### About `--enable-linger`

A systemd **user** timer only fires while you have a session. If your machine is
on but you are not logged in at 06:00, the ping that matters most — the one after
the overnight gap — never happens.

Lingering fixes that, at the cost of a root-owned file under
`/var/lib/systemd/linger/`. It is opt-in because it is the only step needing
elevated privileges, and because many people already have it on for other
services. The installer records whether *it* enabled it; `uninstall.sh` only
turns it back off if it did, and will never disable lingering you set up
yourself.

## Usage

```sh
claude-keepalive status              # window state, schedule, recent log
claude-keepalive test                # print the exact ping command, send nothing
claude-keepalive schedule            # show the active schedule
claude-keepalive schedule 7,12,17,22 # change the hours in place, no reinstall
claude-keepalive logs 20             # recent log lines
claude-keepalive ping                # what the timer calls
```

`status` and `test` never send anything, so they are always safe to run.

### Changing the hours

```sh
claude-keepalive schedule 7,12,17,22
claude-keepalive schedule --hours "7,12,17,22"    # same thing
```

This rewrites the systemd timer (or crontab entry, or launchd plist), reloads
the scheduler, and updates `HOURS` in your config so everything stays in sync.
No reinstall, no editing unit files by hand.

Hours may be given in any order and are sorted for you. Out-of-range or
non-numeric values are rejected before anything is written.

Editing `HOURS` in the config by hand is *not* enough — the scheduler reads its
own unit file, not your config. Use `schedule`.

## The ping

```sh
claude -p "ok" \
  --model claude-haiku-4-5-20251001 \
  --restricted \
  --strict-mcp-config \
  --no-session-persistence \
  --disable-slash-commands \
  --max-budget-usd 0.05 \
  --output-format text
```

Every flag earns its place:

- `--model` — Haiku is the cheapest, and the window is shared across models, so
  there is no reason to open one with anything pricier.
- `--restricted` — removes the code-running tools *and* ignores your user,
  project and local settings, so none of your hooks fire on a ping.
- `--strict-mcp-config` — with no `--mcp-config` beside it, this loads no MCP
  servers at all. Faster, and no MCP tool definitions bloating the prompt.
- `--no-session-persistence` — the ping is never written to disk, so it does not
  show up in `claude --resume`.
- `--max-budget-usd` — a hard ceiling, because this runs unattended.

## Configuration

`~/.config/claude-keepalive/config`, shell syntax. See
[`config/config.example`](config/config.example).

| Option | Default | |
|---|---|---|
| `HOURS` | `6,11,16,21` | Change with `schedule`, not by hand |
| `SKIP_IF_ACTIVE` | `0` | See above before setting to 1 |
| `WINDOW_HOURS` | `5` | Length of a usage window |
| `MODEL` | `claude-haiku-4-5-20251001` | |
| `PROMPT` | `ok` | |
| `CLAUDE_BIN` | auto | Override binary discovery |
| `MAX_BUDGET_USD` | `0.05` | Per-ping ceiling |
| `PING_TIMEOUT` | `120` | Seconds; 0 disables |
| `LOG_MAX_LINES` | `500` | |

The `claude` binary is discovered at runtime (`$CLAUDE_BIN` → `$PATH` →
`~/.claude/local/claude` → `~/.local/bin` → `/usr/local/bin` → `/usr/bin` →
`/opt/homebrew/bin`), so nothing is tied to one install method.

## Uninstall

```sh
./uninstall.sh             # remove everything, keep config and log
./uninstall.sh --purge     # remove those too
./uninstall.sh --dry-run   # show what would be removed
```

`install.sh` writes an **install manifest** to
`~/.local/state/claude-keepalive/install-manifest` listing every file it created
and every system flag it flipped. `uninstall.sh` reverts exactly that list.

This matters more than it sounds. `~/.config/systemd/user/` and `~/.local/bin/`
are shared with the rest of your system — an uninstaller tidying up with
`rm -rf ~/.config/systemd/user` would take your other user services with it.
Manifest-driven removal touches only the files it wrote.

There is deliberately no journald residue either: the unit sets
`StandardOutput=null` and `StandardError=null`, and the script keeps its own
rotated log. Otherwise every ping would leave journal entries that survive
uninstall, and clearing them would mean `journalctl --vacuum` wiping your whole
user journal rather than just ours.

### What cannot be undone

- **Pings already sent.** Quota spent is spent, and the usage is recorded
  server-side. Nothing is left locally, thanks to `--no-session-persistence`.
- **The repo folder.** `uninstall.sh` lives inside it and does not delete
  itself. Remove it by hand.

## Layout

```
bin/claude-keepalive     the tool
lib/backend.sh           scheduler logic, shared by install.sh and `schedule`
install.sh               manifest-writing installer
uninstall.sh             manifest-reading uninstaller
config/config.example    documented defaults
tests/test.bats          23 tests
```

`lib/backend.sh` is the single source of truth for unit and crontab content, so
the hours you install with and the hours you switch to later are generated by
exactly the same code.

## Requirements

- [Claude Code](https://claude.com/claude-code), logged in
- `bash` 4+
- systemd, launchd, or cron

## Development

```sh
bats tests/
shellcheck bin/claude-keepalive install.sh uninstall.sh lib/backend.sh
```

## License

MIT
