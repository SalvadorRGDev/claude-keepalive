# claude-keepalive

Opens a Claude Code usage window on a schedule — but only when one isn't open
already.

```
claude-keepalive status
```
```
claude-keepalive 1.0.0

claude binary : /usr/bin/claude
config        : ~/.config/claude-keepalive/config
model         : claude-haiku-4-5-20251001
skip-if-active: yes
window        : OPEN (last activity 0h42m ago, closes in 4h18m)
backend       : systemd
```

## Read this first: what it does *not* do

**It does not give you more quota.** Claude's usage window starts with your
first message and runs for five hours. Pinging on a schedule does not add
messages, extend the window, or unlock a bigger allowance.

What it actually does is make your window boundaries *predictable*. Instead of
windows that start whenever you happen to open a terminal, they start at hours
you choose — say 06:00, 11:00, 16:00 and 21:00 — so you always know where you
stand in the current window.

That can also work against you: if a window opens at 06:00 and you sit down at
10:30, you have 30 minutes of it left instead of a fresh five hours. This is why
`SKIP_IF_ACTIVE` is on by default (see below), and why you should pick your
hours to match your actual day.

Also worth stating plainly: automating requests for the purpose of managing
usage limits sits in a gray area of Anthropic's usage policy. This tool is
deliberately conservative — one trivial prompt on the cheapest model, skipped
entirely when unnecessary — but you should decide for yourself whether you want
to run it.

## The part that makes it worth installing

Before every scheduled ping, the tool checks whether a usage window is *already*
open by reading the mtimes of your Claude Code transcripts in
`~/.claude/projects`. If you were working forty minutes ago, the window is
already running and the ping would be pure waste, so it is skipped.

Without this check, a keepalive is just a cron job burning quota four or five
times a day for nothing. With it, it fires only when it would actually change
something. Turn it off with `SKIP_IF_ACTIVE=0` if you want unconditional pings.

## Install

```sh
git clone https://github.com/SalvadorRGDev/claude-keepalive
cd claude-keepalive
./install.sh --dry-run     # see exactly what it would do
./install.sh               # do it
```

Options:

| Flag | Meaning |
|---|---|
| `--hours "6,11,16,21"` | Hours of day to ping. Default `6,11,16,21`. |
| `--backend systemd\|launchd\|cron` | Scheduler. Auto-detected by default. |
| `--prefix DIR` | Install root for the script. Default `~/.local`. |
| `--enable-linger` | Linux: keep the timer alive with no session open. Needs sudo/polkit. Off by default. |
| `--dry-run` | Print every action, perform none. |

Backends are picked automatically: systemd user timers on Linux, launchd on
macOS, cron as a fallback.

### About `--enable-linger`

On Linux, a systemd **user** timer only runs while you have a session. If you
want pings to continue after you log out, you need lingering enabled for your
account, which writes a root-owned file under `/var/lib/systemd/linger/`.

It is opt-in because it is the only step that needs elevated privileges, and
because many people already have lingering on for other services. The installer
records whether *it* enabled it, and `uninstall.sh` only turns it back off if it
did — it will never disable lingering you set up yourself.

## Usage

```sh
claude-keepalive status     # window state, schedule, recent log
claude-keepalive test       # dry-run: print the exact ping command, send nothing
claude-keepalive ping       # open a window now (what the timer calls)
claude-keepalive logs 20    # last 20 log lines
```

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

Every flag is there for a reason:

- `--model` — Haiku is the cheapest model, and the usage window is shared across
  models, so there is no reason to open one with something expensive.
- `--restricted` — removes the code-running tools *and* ignores your user,
  project and local settings files, so none of your hooks fire on a ping.
- `--strict-mcp-config` — with no `--mcp-config` alongside it, this loads no MCP
  servers at all. Faster, and no MCP tool definitions bloating the system prompt.
- `--no-session-persistence` — the ping is not written to disk, so it never
  shows up in `claude --resume`.
- `--max-budget-usd` — a hard ceiling, because this runs unattended.

## Configuration

`~/.config/claude-keepalive/config`, shell syntax. See
[`config/config.example`](config/config.example) for every option: `CLAUDE_BIN`,
`MODEL`, `PROMPT`, `SKIP_IF_ACTIVE`, `WINDOW_HOURS`, `MAX_BUDGET_USD`,
`PING_TIMEOUT`, `LOG_MAX_LINES`.

The `claude` binary is discovered at runtime (`$CLAUDE_BIN` → `$PATH` →
`~/.claude/local/claude` → `~/.local/bin` → `/usr/local/bin` → `/usr/bin` →
`/opt/homebrew/bin`), so nothing is hardcoded to one install method.

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
are shared with the rest of your system — an uninstaller that cleaned up with
`rm -rf ~/.config/systemd/user` would take your other user services with it.
Manifest-driven removal touches only the two unit files it wrote.

### What cannot be undone

- **Pings already sent.** Quota spent is spent, and the usage is recorded
  server-side. Nothing is left locally, thanks to `--no-session-persistence`.
- **The repo folder.** `uninstall.sh` lives inside it and does not delete
  itself. Remove it by hand.

There is deliberately no journald residue: the systemd unit sets
`StandardOutput=null` and `StandardError=null`, and the script keeps its own
rotated log instead. Otherwise every ping would leave entries in your user
journal that survive uninstall, and clearing them would mean
`journalctl --vacuum` wiping your whole journal rather than just ours.

## Requirements

- [Claude Code](https://claude.com/claude-code), logged in
- `bash` 4+
- systemd, launchd, or cron

## License

MIT
