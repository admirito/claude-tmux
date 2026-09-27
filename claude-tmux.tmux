#!/usr/bin/env bash
# claude-tmux loader. tmux runs it once, from ~/.tmux.conf:
#
#   run-shell /path/to/claude-tmux/claude-tmux.tmux
#
# It hooks claude-tmux.sh into the status refresh and gives a window running
# Claude Code its own cell in the window list: the index, a mark for what the
# session is doing in place of the colon, and the session's name. Every other
# window keeps the formats already configured, so this composes with a theme
# instead of replacing it. Running it again, on a config reload or after a
# git pull, rebuilds everything from the settings rather than stacking a
# second copy.
#
# If the repository is gone, that run-shell line is silent and the rest of
# tmux.conf still applies.

# run-shell shows its output in a pane on screen.
exec >/dev/null 2>&1

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 0

# The formats below need tmux 3.2 (#{&&:}, #{e|...}, #{n:}, #{E:}). On an
# older tmux they would blank the window list, so it is left alone.
v=$(tmux -V); v=${v#tmux }; v=${v#next-}
case $v in
  [0-2].*|3.[01]|3.[01][!0-9]*) exit 0 ;;
esac

# A setting's value, or $2 when it is not set. Set-but-empty is a value:
# `set -g @claude-tmux-waiting-style ''` must turn the background off, not
# bring the default back. `show -gv` prints the same nothing for both, and
# exits 0 for both on 3.2, so presence is read from `show -gq`, which prints
# the option's name only when it exists.
setting() {
  if [ -n "$(tmux show -gq "@claude-tmux-$1")" ]; then
    tmux show -gqv "@claude-tmux-$1"
  else
    printf '%s' "$2"
  fi
}

# A mark is literal text in a format; these three characters are not.
esc() {
  local s=$1 hh='##' hc='#,' hb='#}'
  s=${s//"#"/$hh}; s=${s//,/$hc}; s=${s//\}/$hb}
  printf '%s' "$s"
}

# The frames of a mark: one is shown as it is, several turn one step per
# poller run. The step comes from the heartbeat rather than the clock, so it
# advances exactly once per refresh whatever the interval; stepping by
# seconds showed two frames at a 2 s interval, spun backwards at 3 s and
# froze at 4 s.
frames() {
  if [ $# -le 1 ]; then esc "$1"; return; fi
  local step="#{e|m|:#{e|/|:#{@claude_tick},#{status-interval}},$#}"
  local out= close= i=0 f
  for f; do
    if [ $i -lt $(( $# - 1 )) ]; then
      out+="#{?#{==:$step,$i},$(esc "$f"),"; close+='}'
    else
      out+=$(esc "$f")
    fi
    i=$((i + 1))
  done
  printf '%s%s' "$out" "$close"
}

# One channel, one meaning: the mark says what Claude is doing, the
# background that it needs you, and bold (the unseen style) that it has
# something you have not looked at. Text colour is left free for a later
# meaning.
#
# Unseen comes first and the state's style after it, so a state that sets its
# own text colour keeps it and unseen adds only the weight; the other way
# round, unseen's black turned a waiting style with light text on a dark
# background unreadable. Bold alone would come out grey: xterm's boldColors,
# on by default, draws bold in colours 0-7 as their bright versions, and
# colour16 is the same black without that. The window being looked at is
# never unseen, which the format knows at once while the poller only learns
# it at the next refresh.
style= mark=
u=$(setting unseen-style 'fg=colour16,bold')
[ -n "$u" ] &&
  style="#{?#{&&:#{@claude_unseen},#{!=:#{window_active},1}},#[${u//,/#,}],}"

# Per state, a mark and a style. Waiting is the one state in which Claude is
# blocked on you, more urgent than anything merely unseen, so its background
# is dark enough to find at a glance: colour34, one step darker than the
# stock bar, was too faint in practice.
for state in busy shell idle waiting; do
  case $state in
    busy)    m='◐ ◓ ◑ ◒' s= ;;
    shell)   m='◌'       s= ;;
    idle)    m='◉'       s= ;;
    waiting) m='◉'       s='bg=colour28' ;;
  esac
  read -r -a f <<< "$(setting "$state" "$m")"
  s=$(setting "$state-style" "$s")
  is="#{==:#{@claude_state},$state}"
  mark+="#{?$is,$(frames "${f[@]}"),}"
  [ -n "$s" ] && style+="#{?$is,#[${s//,/#,}],}"
done

# The label, spaces made dashes since a space reads as a gap between windows,
# cut in the middle to the width: claude…sline keeps both the family and the
# specific part of a name. 0 means no limit.
width=$(setting width 12)
case $width in ''|*[!0-9]*) width=12 ;; esac
label='#{s/ /-/:@claude_label}'
if [ "$width" -eq 0 ]; then
  name=$label
else
  [ "$width" -ge 3 ] || width=3
  name="#{?#{e|>|:#{n:$label},$width},#{=$(( width / 2 )):$label}…#{=-$(( (width - 1) / 2 )):$label},$label}"
fi

# Published as formats, so a theme can place them itself: #{E:@claude_mark}.
tmux set -g @claude_mark "$mark" \; set -g @claude_style "$style" \
  \; set -g @claude_name "$name"

# The Claude cell applies only while the poller's heartbeat is younger than
# three status intervals, so a poller that stops for any reason leaves the
# configured look rather than the last state it saw. Written as "tick > now -
# 3 * interval" because tmux arithmetic on a non-number yields empty, and empty
# compares as 0: the obvious "now - tick < 3 * interval" took an unset or
# garbage tick for a fresh one.
fresh='#{e|>|:#{@claude_tick},#{e|-|:%s,#{e|*|:#{status-interval},3}}}'
cell='#{E:@claude_style}#I#{E:@claude_mark}#{E:@claude_name}#[default]'
cell+='#{?window_flags,#{window_flags}, }'

# Each original format is kept in a user option the first time and reached
# through #{E:}, never pasted into the conditional: a theme's #[fg=..,bg=..]
# carries commas that would split it. Our own format carries @claude_tick; a
# format that uses the published options without it places them itself and
# is left alone; any other format was set afresh, by a theme or an edited
# tmux.conf, and becomes the new original.
for pair in window-status-format:@claude_orig_format \
            window-status-current-format:@claude_orig_current_format; do
  opt=${pair%%:*} keep=${pair#*:}
  cur=$(tmux show -gv "$opt")
  case $cur in
    *@claude_tick*) orig=$(tmux show -gqv "$keep") ;;
    *@claude_*) continue ;;
    *) orig=$cur; tmux set -g "$keep" "$orig" ;;
  esac
  # Nothing to fall back on: leave the format alone rather than blank it.
  [ -n "$orig" ] || continue
  tmux set -g "$opt" "#{?#{&&:$fresh,#{@claude_state}},$cell,#{E:$keep}}"
done

# The poller rides on the status refresh, the way tmux-continuum runs its
# autosave. Its output is empty, so it takes no room in status-right.
job="#('$dir/claude-tmux.sh')"
case $(tmux show -gv status-right) in
  *"$job"*) ;;
  *) tmux set -ga status-right "$job" ;;
esac
