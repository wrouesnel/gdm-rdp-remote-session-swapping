#!/bin/bash
# End-to-end test of GNOME local <-> RDP session handoff (patched mutter/gdm3/g-r-d).
# Runs on the hypervisor host against test VMs only.
# Usage: test/gnome-e2e.sh <target-domain> <target-ip> <client-ip> <user> <password> <gw-user> <gw-pass> [cycles]
# The target must have a local session logged in on seat0 with ~/marker.txt open in
# gnome-text-editor (focused). The client VM needs Xvfb, xfreerdp3, xdotool, imagemagick.
set -uo pipefail
DOM=$1; TIP=$2; CIP=$3; U=$4; PW=$5; GWU=$6; GWP=$7; CYCLES=${8:-2}
HERE=$(cd "$(dirname "$0")" && pwd); SHOTS="$HERE/../shots/gnome-e2e"; mkdir -p "$SHOTS"
"$HERE/check-gdm-config" "$U" "$TIP" || exit 1
tgt() { ssh -o BatchMode=yes "$U@$TIP" "$@"; }
cli() { ssh -o BatchMode=yes "$U@$CIP" "$@"; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi; }
wait_for() { local i; for i in $(seq 1 "$1"); do eval "$2" && return 0; sleep 1; done; return 1; }
seat_session() { tgt "loginctl list-sessions --no-legend | awk '\$2==$(tgt id -u) && \$4==\"seat0\" {print \$1}'"; }
SID=$(seat_session)
seat_active_class() { tgt "loginctl show-session \$(loginctl show-seat seat0 -p ActiveSession --value) -p Class --value"; }
# Connector names of the monitors mutter currently exposes via DisplayConfig.
monitors() { tgt "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig --method org.gnome.Mutter.DisplayConfig.GetCurrentState" | grep -oE "\(\('[A-Za-z0-9-]+'" | tr -d "(\'" | sort | tr '\n' ' ' | sed 's/ $//'; }
inhibited() { tgt "systemd-inhibit --list --no-legend 2>/dev/null | grep -c 'GNOME Remote Desktop'" | awk '{print ($1>0)?"yes":"no"}'; }
grab_remote() { cli "DISPLAY=:77 xwd -root -silent | convert xwd:- /tmp/r.png" && scp -q "$U@$CIP:/tmp/r.png" "$SHOTS/$1.png"; }

echo "== local seat session: $SID"
check "local session active on seat0" "$(tgt loginctl show-session "$SID" -p Active --value)" "yes"

for c in $(seq 1 "$CYCLES"); do
  echo "== cycle $c: remote logon via gateway + remote login screen"
  cli "pkill -u \$USER -x xfreerdp3; pkill -u \$USER -x Xvfb; sleep 1; (Xvfb :77 -screen 0 1600x900x24 >/dev/null 2>&1 &); sleep 1; (DISPLAY=:77 setsid xfreerdp3 /v:$TIP /u:$GWU /p:'$GWP' /cert:ignore /size:1600x900 /log-level:INFO </dev/null >/tmp/gremote.log 2>&1 &)"
  sleep 15; grab_remote "c$c-1-remote-greeter"
  cli "export DISPLAY=:77; xdotool key Return; sleep 2; xdotool type --delay 60 '$PW'; xdotool key Return"
  wait_for 30 "[ \"\$(tgt loginctl show-session $SID -p Active --value)\" = no ]"
  sleep 8
  virsh screenshot "$DOM" "$SHOTS/c$c-2-console-during-remote.png" >/dev/null
  grab_remote "c$c-2-remote-desktop"
  check "c$c: local session inactive (console released)" "$(tgt loginctl show-session "$SID" -p Active --value)" "no"
  check "c$c: seat0 shows a greeter" "$(seat_active_class)" "greeter"
  check "c$c: only the virtual monitor is in the layout" "$(monitors)" "Meta-0"
  check "c$c: sleep inhibited while remote" "$(inhibited)" "yes"
  check "c$c: session streamed to remote client" "$(tgt "journalctl --user -u gnome-remote-desktop-handover --since -40s --no-pager | grep -c 'PipeWire stream state changed from paused to streaming'" | awk '{print ($1>0)?"yes":"no"}')" "yes"

  echo "== cycle $c: remote types into the session; physical keyboard types too"
  cli "export DISPLAY=:77; xdotool mousemove 200 300 click 1; sleep 1; xdotool key ctrl+End; xdotool type --delay 50 ' remote$c'"
  sleep 1
  "$HERE/vm-type" "$DOM" "leak"
  sleep 1
  cli "export DISPLAY=:77; xdotool key ctrl+s"
  if ! wait_for 5 "[ \"\$(tgt grep -c 'remote$c' ~/marker.txt)\" = 1 ]"; then
    echo "NOTE: c$c: first Ctrl+S did not register, retrying"
    cli "export DISPLAY=:77; xdotool key ctrl+s"; wait_for 5 "[ \"\$(tgt grep -c 'remote$c' ~/marker.txt)\" = 1 ]"
  fi
  grab_remote "c$c-3-remote-after-typing"
  check "c$c: remote input reached the session" "$(tgt "grep -c 'remote$c' ~/marker.txt")" "1"
  check "c$c: physical input did not reach the session" "$(tgt "grep -c leak ~/marker.txt")" "0"

  echo "== cycle $c: local login at seat0 takes the session back"
  virsh send-key "$DOM" KEY_ESC >/dev/null; sleep 1
  virsh send-key "$DOM" KEY_ENTER >/dev/null; sleep 2
  "$HERE/vm-type" "$DOM" "$PW" --enter
  wait_for 20 "[ \"\$(tgt loginctl show-session $SID -p Active --value)\" = yes ]"
  sleep 5
  virsh screenshot "$DOM" "$SHOTS/c$c-4-console-reclaimed.png" >/dev/null
  check "c$c: local session active again" "$(tgt loginctl show-session "$SID" -p Active --value)" "yes"
  check "c$c: remote client disconnected" "$(cli "pgrep -u \$USER -x xfreerdp3 >/dev/null && echo running || echo exited")" "exited"
  check "c$c: physical monitor restored" "$(monitors)" "Virtual-1"
  check "c$c: sleep inhibitor released" "$(inhibited)" "no"
  check "c$c: remote told it was logged off" "$(cli "grep -c 'ERRINFO_LOGOFF_BY_USER' /tmp/gremote.log" | awk '{print ($1>0)?"yes":"no"}')" "yes"
done
cli "pkill -u \$USER -x Xvfb" || true
echo "== $pass passed, $fail failed (screenshots in $SHOTS)"
[ "$fail" -eq 0 ]
