#!/usr/bin/env bash
# claude-tmux mirrors: more terminals on one tmux session, each showing a
# window of its own.
#
# A mirror is a session in the same group as another: tmux shares the windows
# between them, while each keeps a current window of its own. Two terminals
# attached to one session move together; a terminal on a mirror moves on its
# own. The loader makes this reachable as a command at tmux's prompt, `mirror`
# by default, and on a key for those who ask for one. Both run
#
#   claude-tmux-mirror.sh menu CLIENT SESSION
#
# which shows tmux's own menu in the terminal of CLIENT, attached to SESSION.
# The menu's items run this script again:
#
#   new CLIENT SESSION          open a new terminal on a mirror of SESSION
#   join CLIENT SESSION TARGET  turn CLIENT's terminal into a mirror of
#                               TARGET, as choose-tree names it: =main: or
#                               =main:2.
#   close-all CLIENT SESSION    close every mirror of SESSION's group
#
# and a terminal opened by `new` runs it once more to attach itself:
#
#   attach SOCKET SESSION WINDOW
#
# Session and window ids travel as plain numbers, without their $ and @, so
# that nothing on the way, a shell, AppleScript or a terminal's own parsing of
# its command, can take them for anything else. The session is passed at
# all, rather than found from the client's pane, because a pane of a group is
# in every session of the group.
#
# Every mirror made here carries @claude_mirror. tmux's own session_grouped
# does not tell a mirror from the session it mirrors, since both are in the
# group once a mirror exists. The close items never touch a session without
# the mark.
#
# Fields read from tmux are separated by ":", which tmux turns into "_" in a
# session's name, so no name holds one; a field that could, a command's name,
# comes last, where read keeps the rest of the line whole.

# A tmux server can run its commands with the bare system PATH, as one on
# macOS did, where a Homebrew tmux is not found. Appended, so the system's own
# tools still come first.
PATH=$PATH:/opt/homebrew/bin:/usr/local/bin

script=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")

# A mirror goes with its last terminal. keep-last, from tmux 3.4 on, spares
# one that has become the last session of its group, and with it the windows,
# as after the session it mirrored was killed; earlier versions only know on.
destroy() {
  local v
  v=$(tmux "$@" display -p '#{version}'); v=${v#next-}
  case $v in
    ''|[0-2].*|3.[0-3]|3.[0-3][!0-9]*) echo on ;;
    *) echo keep-last ;;
  esac
}

# What the mirrors of session $1 are named and titled after, in $base, tmux
# options such as -S SOCKET following; every session's name, in $taken. For
# a session in no group, its own name; in a group, the name of the group's
# session without the mark, the one mirrored, under the name it has now. The
# group's own name is fixed when the group forms and goes stale when that
# session is renamed, so it serves only when no such session is left.
origin() {
  local s=$1 out group own mark g n found=
  shift
  out=$(tmux "$@" display -p -t "$s" '#{session_group}:#{session_name}' \
    \; list-sessions -F '#{@claude_mirror}:#{session_group}:#{session_name}')
  IFS=: read -r group own <<< "${out%%$'\n'*}"
  base=$own taken=
  [ -n "$group" ] && base=$group
  while IFS=: read -r mark g n; do
    taken+=$n$'\n'
    if [ -n "$group" ] && [ -z "$found" ] && [ -z "$mark" ] && [ "$g" = "$group" ]; then
      base=$n found=1
    fi
  done <<< "${out#*$'\n'}"
}

# A name for a new mirror of session $1, tmux options following: its origin
# and the first free letter, 0a, 0b, with a dash after a name that ends in a
# letter, work-a rather than worka. Left to tmux, a session in a group is
# named after the group and its id, a count of every session the server has
# made, which reads as noise: 0-29. When all 26 letters are taken, nothing,
# and tmux names it after all.
mirrorname() {
  local base taken l
  origin "$@"
  [ -n "$base" ] || return
  case $base in *[A-Za-z]) base=$base- ;; esac
  for l in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
    printf '%s' "$taken" | grep -qxF "$base$l" && continue
    printf '%s' "$base$l"
    return
  done
}

# The new terminal's own tmux client, replacing this script: it creates the
# mirror, names and marks it, and starts it on the window the terminal was
# asked from, since a new session in a group starts on the group's first
# window. A terminal given a command runs it without a shell, so a shell set
# to start tmux does not make a session of its own on the way; macOS's
# Terminal is the exception, since it types the command into a login shell.
if [ "$1" = attach ]; then
  sock=$2 sid=$3 wid=$4
  case $sid$wid in ''|*[!0-9]*) exit 1 ;; esac
  unset TMUX TMUX_PANE
  name=$(mirrorname "\$$sid" -S "$sock")
  opt=()
  [ -n "$name" ] && opt=(-s "$name")
  exec tmux -S "$sock" new-session -t "\$$sid" "${opt[@]}" \
    \; set destroy-unattached "$(destroy -S "$sock")" \; set @claude_mirror 1 \
    \; select-window -t ":@$wid"
fi

# Everything else runs from run-shell, which shows whatever it prints in a
# pane on screen.
exec >/dev/null 2>&1

client=$2 n=${3#\$}
case $n in ''|*[!0-9]*) exit 0 ;; esac
sid=\$$n
[ -n "$client" ] || exit 0

# A message in the status line of the terminal that asked. It is a format, so
# a # in a session name is doubled. tmux 3.2 took display-message's -c for a
# flag without its argument and refused the call; without -c the message
# goes to the terminal used last, which is the one that just used the menu.
say() {
  local m=$1
  m="claude-tmux: ${m//\#/##}"
  tmux display-message -c "$client" "$m" || tmux display-message "$m"
}

# A setting's value, or $2 when it is not set; as in the loader.
setting() {
  if [ -n "$(tmux show -gq "@claude-tmux-$1")" ]; then
    tmux show -gqv "@claude-tmux-$1"
  else
    printf '%s' "$2"
  fi
}

# The menu, built afresh each time, so its items can say whether they apply:
# a greyed item, as in tmux's own menus, keeps the menu the same shape and its
# letters in the same places.
menu() {
  local mine group id tag g total=0 others=0 this all args base taken
  IFS=: read -r mine group <<< "$(tmux display -p -t "$sid" '#{@claude_mirror}:#{session_group}')"
  if [ -n "$group" ]; then
    while IFS=: read -r id tag g; do
      [ "$tag" = 1 ] && [ "$g" = "$group" ] || continue
      total=$((total + 1))
      [ "$id" = "$sid" ] || others=$((others + 1))
    done <<< "$(tmux list-sessions -F '#{session_id}:#{@claude_mirror}:#{session_group}')"
  fi
  origin "$sid"
  # "Close all" closes this one too when it is a mirror, so it counts it,
  # but applies only when there is another: alone, "Close this" says it.
  this='-Close this mirror'
  [ "$mine" = 1 ] && this='Close this mirror'
  all='-Close all mirrors'
  [ "$others" -gt 0 ] && all="Close all mirrors ($total)"
  args="'$client' '$n'"
  tmux display-menu -c "$client" -t "$sid" -x C -y C \
    -T "#[align=centre] Mirrors of ${base//\#/##} " \
    'New terminal mirroring this session' n "run-shell -b \"'$script' new $args\"" \
    'Make this terminal a mirror...' t \
      "choose-tree -Zs \"run-shell -b \\\"'$script' join $args '%%'\\\"\"" \
    '' \
    "$this" c detach-client \
    "$all" a "run-shell -b \"'$script' close-all $args\""
}

# Whether a pane runs nothing but a shell, as in a terminal just opened.
isshell() {
  case ${1#-} in
    sh|bash|zsh|fish|dash|ksh|mksh|oksh|tcsh|csh|ash|yash|nu|elvish|"$2") return 0 ;;
  esac
  return 1
}

# Turn this terminal into a mirror of the chosen session, starting on the
# chosen window, or on that session's current one when a session was chosen.
# The session it leaves is removed only when nothing is lost with it: a
# mirror whose windows a session of its group without the mark still holds,
# or a session of its own holding one idle shell, like the one a new terminal
# starts, unless that is the session chosen, whose window would then live on
# only in a mirror. Anything else stays, and a message says so.
join() {
  local target=$1 omine ogroup owins opanes oatt oname oshell ocmd tsid twid m
  local name opt=()
  IFS=: read -r omine ogroup owins opanes oatt oname oshell ocmd <<< \
    "$(tmux display -p -t "$sid" '#{@claude_mirror}:#{session_group}:#{session_windows}:#{window_panes}:#{session_attached}:#{session_name}:#{b:default-shell}:#{pane_current_command}')"
  IFS=: read -r tsid twid <<< "$(tmux display -p -t "$target" '#{session_id}:#{window_id}')"
  [ -n "$oatt" ] && [ -n "$tsid" ] || return
  name=$(mirrorname "$tsid")
  [ -n "$name" ] && opt=(-s "$name")
  m=$(tmux new-session -d -t "$tsid" "${opt[@]}" -P -F '#{session_id}') || return
  # The terminal first, the mark after: tmux destroys a session nobody is on
  # the moment it is marked disposable, and on tmux 3.2 the commands after
  # the mark in the same call then crashed the server.
  if ! tmux switch-client -c "$client" -t "$m" \
      \; set -t "$m" destroy-unattached "$(destroy)" \; set -t "$m" @claude_mirror 1; then
    tmux kill-session -t "$m"
    return
  fi
  tmux select-window -t "$m:$twid"
  # Someone else is still on the session it left: nothing to tidy or report.
  [ "$oatt" -le 1 ] || return
  if [ "$omine" = 1 ]; then
    if tmux list-sessions -F '#{@claude_mirror}:#{session_group}' | grep -qxF ":$ogroup"; then
      tmux kill-session -t "$sid"
      return
    fi
  elif [ "$tsid" != "$sid" ] && [ -z "$ogroup" ] && [ "$owins" = 1 ] &&
      [ "$opanes" = 1 ] && isshell "$ocmd" "$oshell"; then
    tmux kill-session -t "$sid"
    return
  fi
  say "session $oname is still there, detached"
}

# Close the mirrors of this session's group, this terminal's own last.
# Detached rather than killed: with detach-on-destroy off, tmux moves the
# terminals of a killed session to another session instead of letting them
# go. A mirror nobody is on is left alone, since it can only be one keep-last
# kept as the last session of its group.
closeall() {
  local group id att tag g
  group=$(tmux display -p -t "$sid" '#{session_group}')
  [ -n "$group" ] || return
  while IFS=: read -r id att tag g; do
    [ "$tag" = 1 ] && [ "$g" = "$group" ] && [ "$id" != "$sid" ] &&
      [ "$att" -gt 0 ] && tmux detach-client -s "$id"
  done <<< "$(tmux list-sessions -F '#{session_id}:#{session_attached}:#{@claude_mirror}:#{session_group}')"
  [ "$(tmux display -p -t "$sid" '#{@claude_mirror}')" = 1 ] && tmux detach-client -s "$sid"
}

# The terminal a client runs in: the first of its ancestors that is not tmux,
# a shell, or a helper in between such as login or iTerm2's iTermServer.
# "remote" for a client reached over ssh or mosh, whose terminal is on another
# machine; nothing when there is none to find, as for tmux inside tmux. Names
# are as ps gives them, which on Linux cuts them to 15 characters.
terminal() {
  ps -A -o pid= -o ppid= -o comm= | awk -v pid="$1" '
    {
      p = $1; parent[p] = $2
      $1 = $2 = ""; sub(/^ +/, ""); sub(/.*\//, ""); sub(/^-/, "")
      name[p] = $0
    }
    END {
      for (hops = 0; hops < 32 && pid > 1 && (pid in name); hops++) {
        n = name[pid]
        if (n ~ /^(sshd|sshd-session|mosh-server)$/) { print "remote"; exit }
        if (n ~ /^(tmux: server|systemd|launchd|init)$/) exit
        if (n !~ /^(tmux.*|sh|bash|zsh|fish|dash|ksh|mksh|oksh|tcsh|csh|ash|yash|nu|elvish|login|su|sudo|doas|env|iTermServer.*)$/) {
          print n; exit
        }
        pid = parent[pid]
      }
    }'
}

# macOS terminals open a window through AppleScript, given a command line:
# iTerm2 runs it, and Terminal types it into the login shell of the new
# window. Every word is quoted as a shell would need, the whole for
# AppleScript.
apple() {
  local app=$1 line= w
  shift
  for w; do
    line+=" '$(printf '%s' "$w" | sed "s/'/'\\\\''/g")'"
  done
  line=${line# }
  line=${line//\\/\\\\}
  line=${line//\"/\\\"}
  case $app in
    iTerm2)
      osascript -e "tell application \"iTerm2\" to create window with default profile command \"$line\"" ;;
    Terminal)
      osascript -e 'tell application "Terminal"' -e "do script \"exec $line\"" \
        -e activate -e 'end tell' ;;
  esac
}

# Open another window of the terminal this client runs in, on a new mirror of
# its session. @claude-tmux-terminal, words split at spaces, names the command
# that runs a program in a new terminal window; unset, the terminal is found
# by walking up from the client and run as it takes a command. $TERMINAL and
# x-terminal-emulator are not asked, since they need not be the terminal in
# use: on Ubuntu machines using xterm and st, the first was unset and the
# second led to gnome-terminal.
new() {
  local cpid wid sock name term
  cpid=$(tmux list-clients -F '#{client_pid} #{client_name}' |
    awk -v c="$client" '$2 == c { print $1 }')
  IFS=: read -r wid sock <<< "$(tmux display -p -t "$sid" '#{window_id}:#{socket_path}')"
  [ -n "$cpid" ] && [ -n "$wid" ] || return
  set -- "$script" attach "$sock" "$n" "${wid#@}"
  read -r -a term <<< "$(setting terminal '')"
  if [ ${#term[@]} -eq 0 ]; then
    name=$(terminal "$cpid")
    case $name in
      remote)
        say 'tmux is remote: open a terminal, then Make this terminal a mirror'
        return ;;
      '')
        say 'no terminal found to open; set @claude-tmux-terminal'
        return ;;
      iTerm2|Terminal)
        apple "$name" "$@"
        return ;;
      xterm|uxterm|st|urxvt|rxvt|alacritty|konsole|ghostty) term=("$name" -e) ;;
      xfce4-terminal|terminator|mate-terminal) term=("$name" -x) ;;
      gnome-terminal-*) term=(gnome-terminal --) ;;
      kitty|foot) term=("$name") ;;
      wezterm-gui) term=(wezterm start --) ;;
      urxvtd) term=(urxvtc -e) ;;
      *)
        say "unknown terminal $name; set @claude-tmux-terminal"
        return ;;
    esac
  fi
  if ! command -v "${term[0]}"; then
    say "${term[0]} not found; set @claude-tmux-terminal"
    return
  fi
  "${term[@]}" "$@" < /dev/null &
}

case $1 in
  menu) menu ;;
  new) new ;;
  join) join "$4" ;;
  close-all) closeall ;;
esac
