# claude-keepalive

You decide the hours at which a Claude usage window opens — so you decide when
your resets land, and you plan your working day around them instead of guessing.

```
claude-keepalive status
```
```
claude-keepalive 2.0.0

claude binary : /usr/bin/claude
config        : ~/.config/claude-keepalive/config
model         : claude-haiku-4-5-20251001
hours         : 6,11,16,21
next ping     : 16:00 (in 2h13m)
last activity : 0h42m ago — a window is open
backend       : systemd
```

## What it does, and what it does not

**It grants no extra quota.** A Claude usage window starts with your first
message and runs for five hours; the weekly cap above it still applies. Pinging
on a schedule does not extend a window or raise its allowance.

What it gives you is **control over when windows start**. That matters because of
how running out actually plays out: when you exhaust a window's allowance, you
wait for that window to close before you can send anything again. Whether that
wait ends at a time you chose in advance, or at whatever o'clock your first
message happened to land, is the difference between planning around it and being
ambushed by it.

## The one rule that explains everything

**A ping can only ever *open* a window. It can never close one early, and it can
never move a boundary.**

So a ping accomplishes something only if no window is open at the moment it
fires. There is exactly one way to guarantee that mechanically: place it a **whole
number of windows** after another scheduled hour, so it lands precisely on a
boundary.

| Gap from the previous scheduled hour | What the ping does |
|---|---|
| **a multiple of 5 h** (5, 10, 15…) | Lands exactly on a boundary of the chain. Effective whether or not you kept working. The robust shape. |
| **less than 5 h** | Lands inside the window the earlier hour opened. Opens nothing, ever. `install.sh` and `schedule` warn about it. |
| **anything else** (8 h, 12 h…) | Lands mid-window if you worked straight through, so it only does something when you were genuinely away. Deliberate for a real break; a trap otherwise. |

### Why `6,14,22` looks reasonable and is not

It reads like three sessions for three work blocks. Follow it hour by hour, for
someone who starts at 08:00 and keeps going:

```
06:00   ping opens a window                    → expires 11:00
08:00   you start working
11:00   the window expires, and since you are still at the keyboard your
        own next message opens the following one → expires 16:00
14:00   ping fires INSIDE that window           → opens nothing. Wasted.
```

Eight hours is not a multiple of five, so 14:00 misses the boundary at 11:00 and
misses the next one at 16:00 too. The schedule promises three sessions and
delivers two. `schedule` now prints a note when an hour sits off the boundaries
like this.

## Choosing your hours

### A normal two-session workday — `8,13`

The one to copy if you just want two sessions covering an ordinary day.

```
08:00   ping → session 1 opens                 → expires 13:00
13:00   ping → fires exactly as it expires,
               so session 2 opens here         → expires 18:00
18:00   you stop; nothing is scheduled after
```

Two full sessions spanning 08:00–18:00, with resets at **13:00 and 18:00** every
day. Five hours apart, so both pings land on boundaries and neither can ever be
wasted — it does not matter whether you worked straight through the morning or
stepped out at 11:00, session 2 still starts at 13:00.

### Front-loading, to reach the first reset sooner — `6,11,16`

Same 08:00 start, but the first ping goes at 06:00 on purpose.

```
06:00   ping → window opens                    → expires 11:00
08:00   you start — 3 h of that window left
11:00   reset → session 2                      → expires 16:00
16:00   reset → session 3                      → expires 21:00
```

You reach your first reset after **three hours of work instead of five**. If you
tend to burn an allowance in two or three hours, an earlier boundary is worth
more to you than a later one. The 06:00–08:00 stretch spent while you are away
costs nothing, because the allowance is per window, not per hour — see below.

### Two blocks with a real break — `6,18`

Mornings from 08:00, evenings from 20:00, genuinely away in between.

```
06:00   ping → window opens                    → expires 11:00
08:00   you start
11:00   reset; your next message carries you through to 13:00
13:00   you stop — nothing is scheduled here, so no ping is spent
        while you are away from the keyboard
16:00   that window quietly expires with you not in it
18:00   ping → nothing is open, so it opens a session → expires 23:00
20:00   you start — 3 h left, reset at 23:00
```

Twelve hours is not a multiple of five, so `schedule` prints a note about 18:00.
The note is right to be cautious and you are right to ignore it *here*: the ping
works because the break is real. Stay at the keyboard past 16:00 and a window
will already be open at 18:00, and that ping does nothing.

If you want the same two blocks without depending on the break actually
happening, use **`8,13,18`** instead. Every hour is five apart, so 18:00 lands on
a boundary regardless of what you did at lunch. The price is the 13:00 ping
opening a window you mostly will not use — one trivial request.

### Continuous coverage — `6,11,16,21`

The default, and the set-and-forget option. Five hours apart all the way, so a
window is always open from 06:00 until 02:00 the next morning.

```
06:00   ping → window to 11:00
11:00   ping → window to 16:00
16:00   ping → window to 21:00
21:00   ping → window to 02:00
```

Resets at **11:00, 16:00, 21:00 and 02:00**, every day, regardless of what you
did in between. Pick this if your hours are unpredictable and you simply want the
boundaries to stop moving.

### The point

The schedule is a list of statements: *"guarantee me a window at this hour."*
Line those hours up with the starts of your working blocks — keeping them a whole
number of windows apart wherever you cannot promise you will be away — and you
get absolute control over when Claude's windows open, and therefore over when
your resets arrive.

The tool refuses nothing. It warns about pings that can never do anything, notes
the ones whose usefulness depends on you actually being idle, and stays quiet
about the rest.

```sh
claude-keepalive schedule 8,13          # two sessions, ordinary workday
claude-keepalive schedule 6,11,16       # front-loaded, earlier first reset
claude-keepalive schedule 8,13,18       # two blocks, break-proof
claude-keepalive schedule 6,11,16,21    # continuous coverage
```

## Why pings are unconditional

Version 1.x had a `SKIP_IF_ACTIVE` option that skipped the ping when you had
been active recently, on the theory that it saved a pointless request. It was
removed in 2.0.0, and the reason is worth stating because it is not a matter of
taste.

Such a check can only ask *"was there activity in the last five hours?"* That is
not the same question as *"is a window open?"*, and it answers wrongly at exactly
the moment a ping matters. If a window opened at `T` and your last message was at
`A` (with `T < A < T+5`), then at `T+5` — when the window expires and the ping is
due — the age of that activity is `T+5−A`, which is **less than five hours**. The
check says "skip" at every single boundary.

Getting it right would require knowing when the window *started*, which local
data does not reliably give us. A heuristic that cannot be made correct with the
information available should not exist, so it does not. Pings always fire.

What the window detection is still good for is reporting: `status` tells you when
you were last active and whether a window is open. It does not claim to know when
that window closes, because from mtimes alone it cannot.

## The honest caveat

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
on but you are not logged in at 06:00, the ping that matters most — the one that
opens your first window of the day — never happens.

Lingering fixes that, at the cost of a root-owned file under
`/var/lib/systemd/linger/`. It is opt-in because it is the only step needing
elevated privileges, and because many people already have it on for other
services. The installer records whether *it* enabled it; `uninstall.sh` only
turns it back off if it did, and will never disable lingering you set up
yourself.

## Usage

```sh
claude-keepalive status              # next ping, window state, recent log
claude-keepalive test                # print the exact ping command, send nothing
claude-keepalive schedule            # show the active schedule
claude-keepalive schedule 8,13       # change the hours in place, no reinstall
claude-keepalive logs 20             # recent log lines
claude-keepalive ping                # what the timer calls
```

`status` and `test` never send anything, so they are always safe to run.

### Changing the hours

```sh
claude-keepalive schedule 8,13
claude-keepalive schedule --hours "8,13"    # same thing
```

This rewrites the systemd timer (or crontab entry, or launchd plist), reloads the
scheduler, and updates `HOURS` in your config so everything stays in sync. No
reinstall, no editing unit files by hand.

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
tests/test.bats          28 tests
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
