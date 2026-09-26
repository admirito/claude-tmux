#!/usr/bin/env bash
# claude-tmux: mark each tmux window with the state of the Claude Code session
# running in it.
#
# tmux runs this from #() in status-right on every status refresh, once per
# attached client. It prints nothing. It reads the registry Claude Code keeps
# in ~/.claude/sessions/<pid>.json and writes tmux user options, which the
# window formats set up by claude-tmux.tmux render:
#
#   @claude_state   per window: busy, shell, idle or waiting; unset when no
#                   Claude runs in the window, and the others with it
#   @claude_label   per window: the session's name if one was chosen, else
#                   its project directory's name
#   @claude_seen    per window: epoch seconds when an attached client last
#                   showed it, as of the last refresh
#   @claude_unseen  per window: 1 when the session's status has changed since
#                   then and it is not busy: an answer, a question or a report
#                   you have not looked at yet
#   @claude_tick    global: epoch seconds of the last run, a heartbeat. The
#                   formats ignore the rest once the tick is three status
#                   intervals old, so a poller that stops, for any reason,
#                   leaves the configured bar rather than the last state it saw.

# tmux puts the last line of a status command's stdout into the bar and parses
# it for #[...] styles, so one stray line would restyle the bar. It discards
# stderr already; silence both regardless.
exec >/dev/null 2>&1

sessions=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions
command -v jq || exit 0
[ -d "$sessions" ] || exit 0
now=$(date +%s)

# "pid status label changed", tab-separated, one line per session, changed
# being when the status last changed in epoch seconds (0 when unrecorded,
# which is never news). Each file is read on its own and the lines go through
# one jq in raw mode, so a file caught half-written is skipped instead of
# taking the rest down with it: the files end without a newline, so `jq -R`
# over several of them glues them into one unparsable line, and plain `jq`
# stops at the first parse error. The glob leaves out the <pid>.<hash>.key
# files beside them.
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
          | if . == "" then "claude" else . end ),
        ( if (.statusUpdatedAt | type) == "number"
          then .statusUpdatedAt / 1000 | floor else 0 end ) ]
    | map(tostring) | join("\t")'
)

procs=$(ps -A -o pid= -o ppid=)
panes=$(tmux list-panes -a -F "$(printf '%s\t' '#{pane_pid}' '#{window_id}' \
  '#{window_active_clients}' '#{@claude_state}' '#{@claude_label}' \
  '#{@claude_seen}' '#{@claude_unseen}')")

# "window option value", separated by \037, for each per-window option whose
# value must change; an empty value means unset it. Only changes are written,
# since the window being looked at gets a new seen stamp on every run.
changes=$(
  {
    echo '#registry'; echo "$registry"
    echo '#procs';    echo "$procs"
    echo '#panes';    echo "$panes"
  } | awk -v now="$now" '
    /^#/ { part = $0; next }
    part == "#registry" {
      split($0, f, "\t")
      status[f[1]] = f[2]; label[f[1]] = f[3]; changed[f[1]] = f[4]
      next
    }
    part == "#procs" { parent[$1] = $2; next }
    part == "#panes" {
      split($0, f, "\t")
      window[f[1]] = w = f[2]
      viewers[w] = f[3]
      have[w, "state"] = f[4]; have[w, "label"] = f[5]
      have[w, "seen"] = f[6];  have[w, "unseen"] = f[7]
      next
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
        if (!(w in best) || rank[status[pid]] > rank[status[best[w]]])
          best[w] = pid
      }
      for (w in viewers) {
        if (w in best) {
          pid = best[w]
          want["state"] = status[pid]
          want["label"] = label[pid]
          # Seen now if an attached client shows the window. A window met
          # for the first time counts as seen too: whatever happened in it
          # before is unknown, and unknown is not news.
          seen = have[w, "seen"]
          if (viewers[w] + 0 > 0 || seen == "") seen = now
          want["seen"] = seen
          want["unseen"] = ""
          if (status[pid] != "busy" && changed[pid] + 0 > seen + 0)
            want["unseen"] = 1
        } else {
          want["state"] = want["label"] = want["seen"] = want["unseen"] = ""
        }
        for (k in want)
          if (want[k] != have[w, k]) print w "\037" k "\037" want[k]
      }
    }'
)

# One tmux call for the heartbeat and every change, heartbeat first: a command
# that fails drops the rest of its group, so a window closed since
# list-panes would otherwise take the heartbeat down with it. A dropped change
# is redone on the next run, which compares against what is shown. Two
# clients run this at the same moment and write the same values, which is
# harmless.
cmd=(set -g @claude_tick "$now")
while IFS=$'\037' read -r w key value; do
  [ -n "$w" ] || continue
  if [ -n "$value" ]; then
    cmd+=(\; set -w -t "$w" "@claude_$key" "$value")
  else
    cmd+=(\; set -uw -t "$w" "@claude_$key")
  fi
done <<< "$changes"
tmux "${cmd[@]}"
