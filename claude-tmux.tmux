#!/usr/bin/env bash
# claude-tmux loader. tmux runs it once, from ~/.tmux.conf:
#
#   run-shell /path/to/claude-tmux/claude-tmux.tmux
#
# It hooks claude-tmux.sh into the status refresh and gives a window running
# Claude Code its own cell in the window list: the index, a mark for what the
# session is doing in place of the colon, and the session's name. Every other
# window keeps the formats already configured, so this composes with a theme
# instead of replacing it. It also adds the menu of claude-tmux-mirror.sh as
# a command at tmux's prompt. Running it again, on a config reload or after a
# git pull, rebuilds everything from the settings rather than stacking a
# second copy.
#
# If the repository is gone, that run-shell line is silent and the rest of
# tmux.conf still applies.

# run-shell shows its output in a pane on screen.
exec >/dev/null 2>&1

# A tmux server can run its commands with the bare system PATH, as one on
# macOS did, where a Homebrew tmux is not found and this loader silently did
# nothing. Appended, so the system's own tools still come first.
PATH=$PATH:/opt/homebrew/bin:/usr/local/bin

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 0

# The formats below need tmux 3.2 (#{&&:}, #{e|...}, #{w:}, #{E:}). On an
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
# background that it needs you, bold (the unseen style) that it has something
# you have not looked at, and the colour of the name that its prompt cache is
# running out.
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

# The prompt cache running out. The points are minutes left on a one-hour
# cache, which the poller scales to the cache's actual TTL: every point but
# the last starts a warning in the next colour of the name; the last starts
# the flash, the one real alarm, where the whole cell takes the flash style
# and the mark flashes to the cold mark; at expiry the cold mark stands. The
# background is what tells the flash from frozen, which never has one: a
# flashing snowflake alone, caught at a glance, read as already frozen and
# too late to act on. A visit acknowledges the current stage, clearing its
# colour and its flash until the next stage begins. The cold mark itself stays
# until a new request warms the cache, but in the cell's own colour once seen:
# blue it is an alarm, black a reminder, and a bar of blue snowflakes nobody
# needs to act on is noise. Busy keeps its spinner, alternating with the cold
# mark: a long command can outlast the cache, and the spinner is how you see
# it is still working. Waiting is left out, since blue does not read on its
# background and it is the loudest cell already.
read -r -a p <<< "$(setting cache-left '30 20 10 5')"
points=$( [ ${#p[@]} -gt 0 ] && printf '%s\n' "${p[@]}" |
  grep -E '^[0-9]+$' | sort -rn | tr '\n' ' ')
read -r -a cs <<< "$(setting cache-styles 'fg=colour18 fg=colour19 fg=colour21')"
fs=$(setting flash-style 'bg=colour117,fg=colour16')
cold=$(setting cold '❄')

waiting='#{==:#{@claude_state},waiting}'
new="#{&&:#{@claude_cache_new},#{&&:#{!=:#{window_active},1},#{!=:$waiting,1}}}"
isflash='#{==:#{@claude_cache},flash}'
cstyle= coldmark=$(esc "$cold") seenmark=$(esc "$cold")
if [ ${#cs[@]} -gt 0 ]; then
  n=${#cs[@]} last=${cs[${#cs[@]} - 1]}
  inner="#[${last//,/#,}]"
  # Under a flash style the background carries the stage, and blue text on
  # light blue would not read.
  [ -n "$fs" ] && inner="#{?$isflash,,$inner}"
  for ((i = n - 2; i >= 0; i--)); do
    inner="#{?#{==:#{@claude_cache},$((i + 1))},#[${cs[i]//,/#,}],$inner}"
  done
  cstyle="#{?$new,$inner,}"
  # The mark's colour must not run on into the name.
  coldmark="#[${last//,/#,}]$coldmark#[default]#{E:@claude_style}"
fi
# Last in the style, over the state's own: the flash is the loudest thing a
# cell can say short of waiting, which it leaves alone.
[ -n "$fs" ] && style+="#{?#{&&:$new,$isflash},#[${fs//,/#,}],}"
if [ -n "$cold" ]; then
  flash='#{e|m|:#{e|/|:#{@claude_tick},#{status-interval}},2}'
  steady="#{&&:#{==:#{@claude_cache},cold},#{&&:#{!=:#{@claude_state},busy},#{!=:$waiting,1}}}"
  blink="#{&&:$new,#{&&:#{||:$isflash,#{==:#{@claude_cache},cold}},$flash}}"
  # On the flash style the snowflake takes the cell's own colour.
  flashmark=$coldmark
  [ -n "$fs" ] && flashmark=$seenmark
  # Busy gone cold keeps its spinner, so its snowflake can only alternate
  # with it; once seen it goes on alternating, in black, like the steady one
  # of an idle window: the snowflake stays until a request warms the cache.
  busycold="#{&&:#{==:#{@claude_cache},cold},#{==:#{@claude_state},busy}}"
  mark="#{?$steady,#{?$new,$coldmark,$seenmark},#{?$blink,#{?$isflash,$flashmark,$coldmark},#{?#{&&:$busycold,$flash},$seenmark,$mark}}}"
fi

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
  # Width, not length: #{n:} counts bytes, so a name with a single
  # accented letter was cut while it still fitted.
  name="#{?#{e|>|:#{w:$label},$width},#{=$(( width / 2 )):$label}…#{=-$(( (width - 1) / 2 )):$label},$label}"
fi

# Published as formats, so a theme can place them itself: #{E:@claude_mark}.
# @claude_cache_left is the poller's, read on every run.
tmux set -g @claude_mark "$mark" \; set -g @claude_style "$style" \
  \; set -g @claude_name "$name" \; set -g @claude_cache_style "$cstyle" \
  \; set -g @claude_cache_left "$points"

# The Claude cell applies only while the poller's heartbeat is younger than
# three status intervals, so a poller that stops for any reason leaves the
# configured look rather than the last state it saw. Written as "tick > now -
# 3 * interval" because tmux arithmetic on a non-number yields empty, and empty
# compares as 0: the obvious "now - tick < 3 * interval" took an unset or
# garbage tick for a fresh one.
fresh='#{e|>|:#{@claude_tick},#{e|-|:%s,#{e|*|:#{status-interval},3}}}'
cell='#{E:@claude_style}#I#{E:@claude_mark}#{E:@claude_cache_style}'
cell+='#{E:@claude_name}#[default]#{?window_flags,#{window_flags}, }'

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

# Mirrors, more terminals on one session each showing a window of its own,
# are reached through a menu: a command at tmux's prompt, `C-b :` then
# `mirror`, and a key only for those who set one. See claude-tmux-mirror.sh.
# The session goes with the client because a pane of a group of sessions is
# in all of them, so the script could not tell which one the terminal is on.
menu="run-shell -b \"'$dir/claude-tmux-mirror.sh' menu '#{client_name}' '#{session_id}'\""

# tmux keeps command names in one array. The entry a previous load added,
# found by the script's name, is replaced rather than stacked, which also
# follows a repository that moved; a name the user already gave a command of
# their own stays theirs.
name=$(setting mirror-command mirror)
aliases=$(tmux show -s command-alias)
for i in $(printf '%s\n' "$aliases" | grep -F claude-tmux-mirror.sh |
    sed -n 's/^command-alias\[\([0-9]*\)\].*/\1/p'); do
  tmux set -su "command-alias[$i]"
done
case $name in
  ''|*[!A-Za-z0-9_-]*) ;;
  *)
    printf '%s\n' "$aliases" | grep -vF claude-tmux-mirror.sh |
      grep -q "^command-alias\[[0-9]*\] \"*$name=" ||
      tmux set -sa command-alias "$name=$menu" ;;
esac

# A key only when one is set, and never over a key bound to something else.
# The key bound last time is remembered, to be let go when the setting
# changes.
key=$(setting mirror-key '')
old=$(tmux show -gqv @claude_mirror_key)
if [ -n "$old" ]; then
  case $(tmux list-keys -T prefix "$old") in
    *claude-tmux-mirror.sh*) [ "$old" = "$key" ] || tmux unbind -T prefix "$old" ;;
  esac
  tmux set -gu @claude_mirror_key
fi
if [ -n "$key" ]; then
  case $(tmux list-keys -T prefix "$key") in
    ''|*claude-tmux-mirror.sh*)
      tmux bind -N 'Mirror menu (claude-tmux)' -T prefix "$key" "$menu" &&
        tmux set -g @claude_mirror_key "$key" ;;
  esac
fi
