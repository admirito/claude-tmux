# Agent guide

Three bash scripts. `claude-tmux.tmux` runs once when tmux loads its
configuration, sets up the window formats and adds the mirror menu's command;
`claude-tmux.sh` runs on every status refresh, reads Claude Code's session
files and writes tmux options; `claude-tmux-mirror.sh` runs when the mirror
menu is asked for, and once more in each terminal it opens. `DESIGN.org` has
the reasoning.

## Constraints

**bash 3.2.** macOS ships it as `/bin/bash`. No `${x^}`, `${x,,}`, `mapfile`,
`readarray`, `declare -A`, `local -n` or `printf '%(%s)T'`. These fail at
runtime rather than at parse time, so a branch carrying one passes every test
until the day it executes. `ps` and `awk` must work in their BSD forms too.

**Print nothing.** Whatever `claude-tmux.sh` writes to stdout lands in the
status bar and is parsed as tmux styling; whatever the loader or the mirror
script prints opens in a pane on screen. All three begin with
`exec >/dev/null 2>&1`, except the mirror script's `attach`, which becomes
the tmux client of a new terminal.

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

Mirrors need terminals. Use stand-ins: a small script named like a terminal
(`xterm`, and `sshd` for the remote case), starting `#!/bin/bash` so `ps`
shows its own name, that runs its `-e` command as a child when it has a tty
and otherwise reopens itself in a new window of the camera server. Drive the
menu by sending keys to the camera's windows. Cover: the greyed items in a
main session, in a mirror and with two mirrors; a new terminal starting on the
window being looked at; making a terminal a mirror from a fresh session, from
one running a program, from the main session and from a mirror, with a
window picked, with the terminal's own session chosen, and from a session
whose name holds a `|`; the names, including a mirror made from a mirror, a
letter freed and reused, and a mirror of a session renamed after its first
mirror; closing one and all with `detach-on-destroy off`; the
remote, unknown-terminal and tmux-in-tmux messages; the key and the command
across reloads, renamed, turned off, and against a key and a command the user
has taken; and `keep-last` on tmux 3.4 or later.

## Commits

Record the reasoning, not just the change. Never put a session URL, an email
address, a hostname, or a machine name in a commit message, a comment, or any
tracked file: this repository is public.
