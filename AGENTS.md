# Agent guide

Two bash scripts. `claude-tmux.tmux` runs once when tmux loads its
configuration and sets up the window formats; `claude-tmux.sh` runs on every
status refresh, reads Claude Code's session files and writes tmux options.
`DESIGN.org` has the reasoning.

## Constraints

**bash 3.2.** macOS ships it as `/bin/bash`. No `${x^}`, `${x,,}`, `mapfile`,
`readarray`, `declare -A`, `local -n` or `printf '%(%s)T'`. These fail at
runtime rather than at parse time, so a branch carrying one passes every test
until the day it executes. `ps` and `awk` must work in their BSD forms too.

**Print nothing.** Whatever `claude-tmux.sh` writes to stdout lands in the
status bar and is parsed as tmux styling; whatever the loader prints opens in a
pane on screen. Both begin with `exec >/dev/null 2>&1`.

**Absent, never wrong.** On unexpected input, a missing tool, or a status the
script does not know, show nothing and leave the user's bar as it was. Never
guess a state.

**Never break tmux.** Nothing may blank the window list or freeze it: the
formats fall back to the user's own through the heartbeat, and the loader does
nothing on a tmux older than 3.2.

**Stay cheap.** A run costs two `jq`, one `ps`, `awk`, `tail` and `date` and
two `tmux` calls, once per refresh per attached client. Extend those rather
than adding more.

## Style

Comments carry the why. Most non-obvious lines exist because of a specific bug,
so name it. No em dashes.

## Testing

Parse every change with bash 3.2 (`/bin/bash -n` on macOS) and try it on a
recent tmux as well as 3.2: bash 5 accepts constructs 3.2 rejects, and tmux
3.4 prints control characters in `-F` output as `_`. Both broke the poller on
macOS while every test on Linux passed.

Never test on the tmux server you are working in. Start a private one with its
own configuration (`tmux -L <name> -f <file>`), unset `TMUX` for every command
aimed at it, and look at its status bar through a client attached inside a
second private server, since `capture-pane` never shows a status line.

Drive the script with a fake registry: files shaped like Claude Code's, whose
pids are processes running in the test server's panes, and transcripts of one
reply line each for the cache. Point the script at them with
`CLAUDE_CONFIG_DIR` on its own command in `status-right`, never in the
server's environment, where every Claude started there would inherit it. The
loader adds its own job whenever it does not find it, and that job reads the
real registry and fights the fake one; put the loader's job text into
`status-right` first inside `#{?0,...,}`, where tmux never runs it.

Cover at least: the four states; two Claude panes in one window; a Claude one
level below a shell; a record whose process is gone; an unknown status; a
half-written file; `status-right` reset after loading; the loader run three
times; a theme-style format with commas in its styles; a setting set to empty;
unseen after a change while another window is shown, cleared by a visit, and
set by a change while no client is attached; each cache stage, the flash,
cold on idle and on busy, a visit clearing a stage and the next stage
colouring again, waiting left alone, and a new request warming it.

## Commits

Record the reasoning, not just the change. Never put a session URL, an email
address, a hostname, or a machine name in a commit message, a comment, or any
tracked file: this repository is public.
