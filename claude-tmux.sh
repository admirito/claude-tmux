#!/usr/bin/env bash
# claude-tmux: mark each tmux window with the state of the Claude Code session
# running in it.
#
# tmux runs this from #() in status-right on every status refresh, once per
# attached client. It prints nothing. It reads the registry Claude Code keeps
# in ~/.claude/sessions/<pid>.json and writes two tmux user options, which the
# window formats set up by claude-tmux.tmux render:
#
#   @claude_state  per window: busy, shell, idle or waiting; unset when no
#                  Claude runs in the window
#   @claude_label  per window: the session's name if one was chosen, else
#                  its project directory's name; unset with @claude_state
#   @claude_tick   global: epoch seconds of the last run, a heartbeat. The
#                  formats ignore @claude_state once the tick is three status
#                  intervals old, so a poller that stops, for any reason,
#                  leaves the stock bar rather than the last state it saw.

# tmux puts the last line of a status command's stdout into the bar and parses
# it for #[...] styles, so one stray line would restyle the bar. It discards
# stderr already; silence both regardless.
exec >/dev/null 2>&1

sessions=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions
command -v jq || exit 0
[ -d "$sessions" ] || exit 0

# "pid status label", tab-separated, one line per session. Each file is read
# on its own and the lines go through one jq in raw mode, so a file caught
# half-written is skipped instead of taking the rest down with it: the files
# end without a newline, so `jq -R` over several of them glues them into one
# unparsable line, and plain `jq` stops at the first parse error. The glob
# leaves out the <pid>.<hash>.key files beside them.
#
# The label is the session's name when it was chosen rather than generated:
# nameSource "user" (/rename) or "peer", or no nameSource at all, which is
# how older versions recorded a chosen name. A generated name is the
# directory plus a suffix ("api-server-3f"), so the directory itself says the
# same with less noise. Control characters and "#" are dropped: tmux would
# read "#[" in a label as a style.
registry=$(
  for f in "$sessions"/[0-9]*.json; do
    [ -f "$f" ] || continue
    line=
    IFS= read -r line < "$f"
    printf '%s\n' "$line"
  done | jq -rR 'fromjson?
    | select((.pid | type) == "number" and (.status | type) == "string")
    | [ .pid, .status,
        ( if (.name | type) == "string"
             and (.nameSource == null or .nameSource == "user" or .nameSource == "peer")
          then .name
          else (.cwd // "") | rtrimstr("/") | split("/") | last // ""
          end
          | gsub("[[:cntrl:]#]"; "") | gsub("^\\s+|\\s+$"; "")
          | if . == "" then "claude" else . end ) ]
    | map(tostring) | join("\t")'
)

procs=$(ps -A -o pid= -o ppid=)
panes=$(tmux list-panes -a -F \
  $'#{pane_pid}\t#{window_id}\t#{@claude_state}\t#{@claude_label}')

# "window state label" for each window whose state or label must change; an
# empty state means unset both.
changes=$(
  {
    echo '#registry'; echo "$registry"
    echo '#procs';    echo "$procs"
    echo '#panes';    echo "$panes"
  } | awk '
    /^#/ { part = $0; next }
    part == "#registry" {
      split($0, f, "\t"); status[f[1]] = f[2]; label[f[1]] = f[3]; next
    }
    part == "#procs" { parent[$1] = $2; next }
    part == "#panes" {
      split($0, f, "\t"); window[f[1]] = f[2]; shown[f[2]] = f[3] "\t" f[4]; next
    }
    END {
      # A window with several Claude panes shows the one that most wants
      # you. A status not in this table, including any a later Claude Code
      # adds, shows nothing rather than a guess.
      rank["busy"] = 1; rank["shell"] = 2; rank["idle"] = 3; rank["waiting"] = 4
      for (pid in status) {
        # A registry record whose process is gone is stale, not idle.
        if (!(status[pid] in rank) || !(pid in parent)) continue
        # Walk up from the Claude process itself (it is the pane process
        # when tmux started it directly) to the pane it runs in. The
        # registry has a tmux field of its own, but it names whichever of a
        # group of sessions was current at startup, older versions omit
        # it, and it does not say which tmux server; walking the process
        # tree skips a Claude under another server, whose ancestors are
        # none of these panes.
        p = pid
        for (hops = 0; hops < 32 && !(p in window) && (p in parent); hops++)
          p = parent[p]
        if (!(p in window)) continue
        w = window[p]
        if (!(w in best) || rank[status[pid]] > rank[best[w]]) {
          best[w] = status[pid]
          want[w] = status[pid] "\t" label[pid]
        }
      }
      for (w in shown) {
        if (!(w in want)) want[w] = "\t"
        if (want[w] != shown[w]) print w "\t" want[w]
      }
    }'
)

# One tmux call for the heartbeat and every change, heartbeat first: a command
# that fails drops the rest of its group, so a window closed since
# list-panes would otherwise take the heartbeat down with it. A dropped change
# is redone on the next run, which compares against what is shown. Two
# clients run this at the same moment and write the same values, which is
# harmless.
cmd=(set -g @claude_tick "$(date +%s)")
while IFS=$'\t' read -r w state label; do
  [ -n "$w" ] || continue
  if [ -n "$state" ]; then
    cmd+=(\; set -w -t "$w" @claude_state "$state"
          \; set -w -t "$w" @claude_label "$label")
  else
    cmd+=(\; set -uw -t "$w" @claude_state \; set -uw -t "$w" @claude_label)
  fi
done <<< "$changes"
tmux "${cmd[@]}"
