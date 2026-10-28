#!/usr/bin/env bash
# claude-tmux: mark each tmux window with the state of the Claude Code session
# running in it.
#
# tmux runs this from #() in status-right on every status refresh, once per
# attached client. It prints nothing. It reads the registry Claude Code keeps
# in ~/.claude/sessions/<pid>.json, or in each configuration folder the
# @claude-tmux-config-dirs setting lists, and the tail of each session's
# transcript for its prompt cache, and writes tmux user options, which the
# window formats set up by claude-tmux.tmux render:
#
#   @claude_state      per window: busy, shell, idle or waiting; unset when no
#                      Claude runs in the window, and the others with it
#   @claude_label      per window: the session's name if one was chosen, else
#                      its project directory's name
#   @claude_seen       per window: epoch seconds when an attached client last
#                      showed it, as of the last refresh
#   @claude_unseen     per window: 1 when the session's status has changed
#                      since then and it is not busy: an answer, a question or
#                      a report you have not looked at yet
#   @claude_cache      per window: how close the prompt cache is to expiring,
#                      1, 2, ... for each warning, then flash, then cold;
#                      unset while it is comfortably warm or unknown
#   @claude_cache_new  per window: 1 when the window has not been on screen
#                      since the current cache stage began
#   @claude_tick       global: epoch seconds of the last run, a heartbeat. The
#                      formats ignore the rest once the tick is three status
#                      intervals old, so a poller that stops, for any reason,
#                      leaves the configured bar rather than the last state it
#                      saw.

# tmux puts the last line of a status command's stdout into the bar and parses
# it for #[...] styles, so one stray line would restyle the bar. It discards
# stderr already; silence both regardless.
exec >/dev/null 2>&1

# A tmux server can run its commands with the bare system PATH, as one on
# macOS did, where neither a Homebrew tmux nor jq is found; this script then
# silently did nothing. Appended, so the system's own tools still come first.
PATH=$PATH:/opt/homebrew/bin:/usr/local/bin

command -v jq || exit 0

# Separated by "#", written "##" in a format: tmux 3.4 prints a tab in -F
# output as "_", which ran every field into one and mapped no window at all,
# while 3.2 kept it. No field but the last can hold a "#": labels have it
# removed below, and the last is taken whole, as all that follows the other
# fields on the first line. The last two are global, the same on every line,
# and read here rather than in tmux calls of their own: the loader's cache
# warning points, minutes left on a one-hour cache, and the configuration
# folders setting, which says where the registry is, so this call comes first.
fields=('#{pane_pid}' '#{window_id}' '#{window_active_clients}'
  '#{@claude_state}' '#{@claude_label}' '#{@claude_seen}' '#{@claude_unseen}'
  '#{@claude_cache}' '#{@claude_cache_new}' '#{@claude_cache_left}')
panes=$(tmux list-panes -a \
  -F "$(printf '%s##' "${fields[@]}")#{@claude-tmux-config-dirs}")
setting=${panes%%$'\n'*}
for _ in "${fields[@]}"; do setting=${setting#*#}; done

# The configuration folders whose sessions are shown. Claude Code keeps its
# registry and transcripts in one, ~/.claude unless CLAUDE_CONFIG_DIR names
# another, and two logins run side by side are two such folders. tmux runs
# this outside every Claude, where a CLAUDE_CONFIG_DIR given to one does not
# reach, so the setting lists the folders in place of the default, separated
# by colons as in PATH, which leaves spaces to the paths. Set to empty it
# counts as unset, unlike the loader's settings: a format prints the same
# nothing for both. tmux leaves a "~" in quotes alone, so it is expanded here.
# A relative path, in the setting or in CLAUDE_CONFIG_DIR, would be relative
# to wherever tmux runs this, and is left out, as is a folder without a
# registry.
if [ -n "$setting" ]; then
  IFS=: read -r -a words <<< "$setting"
else
  words=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
fi
dirs=()
for d in "${words[@]}"; do
  case $d in '~'|'~/'*) d=$HOME${d#'~'} ;; esac
  case $d in /*) ;; *) continue ;; esac
  [ -d "$d/sessions" ] && dirs+=("$d")
done
[ ${#dirs[@]} -gt 0 ] || exit 0
now=$(date +%s)

# "pid status label changed host folder session", tab-separated, one line per
# session, changed being when the status last changed in epoch seconds (0 when
# unrecorded, which is never news), host the process running the session,
# which is pid itself but for a parked one, and folder the index in dirs of
# the folder its record came from. The session id comes last because it can
# be empty: read with a tab in IFS, an empty field in the middle is lost and
# the fields after it shift by one. Each file is read on its own and
# the lines go through one jq in raw mode, so a file caught half-written is
# skipped instead of taking the rest down with it: the files end without a
# newline, so `jq -R` over several of them glues them into one unparsable
# line, and plain `jq` stops at the first parse error. The glob leaves out the
# <pid>.<hash>.key files beside them.
#
# A session sent to the background from its window is parked: the window's
# process stays on as a viewer, and its record is written once more, with a
# parkedJobId, and never again, so its status, name and session id stay as
# they were at that moment. A window showed a cold cache and an old name for
# days while the session in it worked on. The session goes on in a process of
# kind "bg", under no pane, whose record has that id as its jobId; the window
# shows that record, and with none it shows nothing, as Claude Code's own
# session lists leave out a parked record. A restarted job can leave its
# crashed predecessor's record behind, so the one written last wins. A
# background record is shown only through the window that parked it: its
# process runs under the daemon, not a pane; a line of its own listed its
# transcript twice; and on a tree where the daemon sat under a pane it would
# mark that window as well.
#
# Two folders can each hold a record for one pid: a login that crashed leaves
# its record behind, and the pid can come back as a session of another. The
# one written last is the live one; read in folder order, the stale one
# would show a busy session as idle under its old name. A folder listed twice,
# under another spelling or through a link, gives each of its records twice,
# and they collapse the same way; so do a record and its copy in a copied
# folder, where neither is newer and either serves.
#
# The label is the session's name when it was chosen rather than generated:
# nameSource "user" (/rename) or "peer", or no nameSource at all, which is
# how older versions recorded a chosen name. A generated name is the
# directory plus a suffix ("api-server-3f"), so the directory itself says the
# same with less noise. Control characters and "#" are dropped: tmux would
# read "#[" in a label as a style.
registry=$(
  i=0
  for d in "${dirs[@]}"; do
    for f in "$d"/sessions/[0-9]*.json; do
      [ -f "$f" ] || continue
      line=
      IFS= read -r line < "$f"
      printf '%s\t%s\n' "$i" "$line"
    done
    i=$((i + 1))
  done | jq -nrR '[ inputs | index("\t") as $t
      | (.[$t + 1:] | fromjson? | objects) + {dir: (.[:$t] | tonumber)}
      | select((.pid | type) == "number" and (.status | type) == "string") ]
    | ( map(select(.kind == "bg" and (.jobId | type) == "string"))
        | sort_by(.updatedAt) | map({key: .jobId, value: .}) | from_entries
      ) as $job
    | map(select(.kind != "bg")) | group_by(.pid)
    | .[] | max_by(.updatedAt // .statusUpdatedAt // .startedAt // 0)
    | if (.parkedJobId | type) == "string"
      then .pid as $pid | $job[.parkedJobId] // empty | .host = .pid | .pid = $pid
      else .host = .pid end
    | [ .pid, .status,
        ( if (.name | type) == "string"
             and (.nameSource == null or .nameSource == "user" or .nameSource == "peer")
          then .name
          else (.cwd // "") | rtrimstr("/") | split("/") | last // ""
          end
          | gsub("[[:cntrl:]#]"; "") | gsub("^\\s+|\\s+$"; "")
          | if . == "" then "claude" else . end ),
        ( if (.statusUpdatedAt | type) == "number"
          then .statusUpdatedAt / 1000 | floor else 0 end ),
        .host,
        .dir,
        ( .sessionId // "" | tostring ) ]
    | map(tostring) | join("\t")'
)

# "session expires ttl" for each session whose transcript shows when its prompt
# cache was last used, and for how long. The cache lives as long as its TTL
# after the last request; the last main-conversation reply stands in for that
# request, and the latest reply that wrote to the cache says whether it wrote
# the 1-hour or the 5-minute kind. Subagents keep caches of their own and are
# left out. Only the tail of each transcript is read, all in one tail and one
# jq: tail prints a "==> path <==" header before each file when it has more
# than one, hence the /dev/null. A session id becomes part of a path only if it
# looks like one. The transcript is looked for in the folder the session's
# record came from and no other: a second login started from a copy of the
# first one's folder holds stale copies of its transcripts, which would show
# a warm cache as cold, and logins sharing project folders through links would
# have each transcript read once per folder.
cache=$(
  files=()
  while IFS=$'\t' read -r _ _ _ _ _ d sid; do
    # The opening parenthesis is not decoration: inside $( ), bash 3.2
    # takes the ")" of a bare pattern for the end of the substitution and
    # fails to parse the whole script, which bash 5 accepts.
    case $sid in (''|*[!A-Za-z0-9._-]*) continue ;; esac
    for t in "${dirs[$d]}"/projects/*/"$sid".jsonl; do
      [ -f "$t" ] && files+=("$t")
    done
  done <<< "$registry"
  [ ${#files[@]} -gt 0 ] || exit 0
  tail -c 131072 "${files[@]}" /dev/null | jq -nrR '
    reduce inputs as $l ({};
      if ($l | startswith("==> "))
      then .cur = ($l | sub("^==> .*/"; "") | sub("\\.jsonl <==$"; ""))
      else (try ($l | fromjson) catch null) as $e
        | if $e != null and $e.type == "assistant" and ($e.isSidechain | not)
             and ($e.message.usage | type) == "object"
          then .s[.cur].ts = $e.timestamp
            | ($e.message.usage.cache_creation // {}) as $c
            | if ($c.ephemeral_1h_input_tokens // 0) > 0 then .s[.cur].ttl = 3600
              elif ($c.ephemeral_5m_input_tokens // 0) > 0 then .s[.cur].ttl = 300
              else . end
          else . end
      end)
    | .s // {} | to_entries[]
    | (try (.value.ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) as $at
    | select($at != null and .value.ttl != null)
    | "\(.key)\t\($at + .value.ttl)\t\(.value.ttl)"'
)

procs=$(ps -A -o pid= -o ppid=)

# "window option value", separated by \037, for each per-window option whose
# value must change; an empty value means unset it. Only changes are written,
# since the window being looked at gets a new seen stamp on every run.
changes=$(
  {
    echo '#registry'; echo "$registry"
    echo '#cache';    echo "$cache"
    echo '#procs';    echo "$procs"
    echo '#panes';    echo "$panes"
  } | awk -v now="$now" '
    /^#/ { part = $0; next }
    # An empty section still echoes one blank line, which would make an
    # entry with an empty key: an empty cache list then matched every
    # session recorded without an id, and showed it cold.
    /^$/ { next }
    part == "#registry" {
      split($0, f, "\t")
      status[f[1]] = f[2]; label[f[1]] = f[3]; changed[f[1]] = f[4]
      host[f[1]] = f[5]; session[f[1]] = f[7]
      # One session id in the records of two folders, as when a session is
      # resumed in a second login while the first one still holds its
      # record, has a transcript in each, and the cache list keeps one of
      # them by id: a stale copy would show a warm cache as cold. Neither
      # is shown.
      if ((f[7] in folder) && folder[f[7]] != f[6]) twice[f[7]] = 1
      folder[f[7]] = f[6]
      next
    }
    part == "#cache" {
      split($0, f, "\t"); expires[f[1]] = f[2]; ttl[f[1]] = f[3]; next
    }
    part == "#procs" { parent[$1] = $2; next }
    part == "#panes" {
      split($0, f, "#")
      window[f[1]] = w = f[2]
      viewers[w] = f[3]
      have[w, "state"] = f[4];  have[w, "label"] = f[5]
      have[w, "seen"] = f[6];   have[w, "unseen"] = f[7]
      have[w, "cache"] = f[8];  have[w, "cache_new"] = f[9]
      points = f[10]
      next
    }
    END {
      # A window with several Claude panes shows the one that most wants
      # you. A status not in this table, including any a later Claude Code
      # adds, shows nothing rather than a guess.
      rank["busy"] = 1; rank["shell"] = 2; rank["idle"] = 3; rank["waiting"] = 4
      for (pid in status) {
        # A registry record whose process is gone is stale, not idle, and
        # so is the record a parked window shows when its background
        # process is gone.
        if (!(status[pid] in rank) || !(pid in parent) || !(host[pid] in parent))
          continue
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
      npoints = split(points, point, " ")
      for (w in viewers) {
        want["state"] = want["label"] = want["seen"] = want["unseen"] = ""
        want["cache"] = want["cache_new"] = ""
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
          if (status[pid] != "busy" && changed[pid] + 0 > seen + 0)
            want["unseen"] = 1
          # The cache stage, from points in minutes left on a one-hour
          # cache, scaled to the TTL: 30 means half the TTL, on a 5-minute
          # cache too. The last point starts the flash and the expiry itself
          # is cold; the ones before are numbered warnings.
          s = session[pid]
          if (npoints > 0 && s != "" && (s in expires) && !(s in twice)) {
            left = expires[s] - now
            stage = ""; start = 0
            if (left <= 0) { stage = "cold"; start = expires[s] }
            else for (i = npoints; i >= 1; i--) {
              t = point[i] * ttl[s] / 60
              if (left <= t) {
                stage = (i == npoints) ? "flash" : i
                start = expires[s] - t
                break
              }
            }
            want["cache"] = stage
            if (stage != "" && seen + 0 < start + 0) want["cache_new"] = 1
          }
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
