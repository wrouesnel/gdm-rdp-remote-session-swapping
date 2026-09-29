#!/bin/bash
# End-to-end test: remote logon with NO local session starts the user session in the
# background on seat0 (not seat-less/headless); remote clients dropping (abruptly, or
# mid-handover) leave it running and later remote logons take it over again; the
# console can then take it over, and normal takeover cycles work on it afterwards.
# Hypervisor host, test VMs only. The client VM user needs passwordless sudo (iptables).
# Usage: test/gnome-e2e-background.sh <target-domain> <target-ip> <client-ip> <user> <password> <gw-user> <gw-pass> [extra-cycles]
set -uo pipefail
DOM=$1; TIP=$2; CIP=$3; U=$4; PW=$5; GWU=$6; GWP=$7; EXTRA=${8:-2}
HERE=$(cd "$(dirname "$0")" && pwd); SHOTS="$HERE/../shots/gnome-e2e-background"; mkdir -p "$SHOTS"
"$HERE/check-gdm-config" "$U" "$TIP" || exit 1
tgt() { ssh -o BatchMode=yes "$U@$TIP" "$@"; }
cli() { ssh -o BatchMode=yes "$U@$CIP" "$@"; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi; }
wait_for() { local i; for i in $(seq 1 "$1"); do eval "$2" && return 0; sleep 1; done; return 1; }
graphical_session() { tgt "for s in \$(loginctl list-sessions --no-legend | awk '\$3==\"$U\" {print \$1}'); do [ \"\$(loginctl show-session \$s -p Type --value)\" = wayland ] && echo \$s; done | head -1"; }
prop() { tgt "loginctl show-session $1 -p $2 --value"; }
monitors() { tgt "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig --method org.gnome.Mutter.DisplayConfig.GetCurrentState" | grep -oE "\(\('[A-Za-z0-9-]+'" | tr -d "(\'" | sort | tr '\n' ' ' | sed 's/ $//'; }
grab_remote() { cli "DISPLAY=:77 xwd -root -silent | convert xwd:- /tmp/r.png" && scp -q "$U@$CIP:/tmp/r.png" "$SHOTS/$1.png"; }

echo "== precondition: no graphical session for $U"
check "no session for $U" "$(graphical_session)" ""

echo "== remote logon with no local session"
cli "pkill -u \$USER -x xfreerdp3; pkill -u \$USER -x Xvfb; sleep 1; (Xvfb :77 -screen 0 1600x900x24 >/dev/null 2>&1 &); sleep 1; (DISPLAY=:77 setsid xfreerdp3 /v:$TIP /u:$GWU /p:'$GWP' /cert:ignore /size:1600x900 /log-level:INFO </dev/null >/tmp/gremote.log 2>&1 &)"
sleep 15
cli "export DISPLAY=:77; xdotool key Return; sleep 2; xdotool type --delay 60 '$PW'; xdotool key Return"
wait_for 60 "[ -n \"\$(graphical_session)\" ]"
SID=$(graphical_session)
wait_for 60 "tgt \"journalctl --user -u gnome-remote-desktop-handover --no-pager -b | grep -q 'paused to streaming'\""
sleep 5
virsh screenshot "$DOM" "$SHOTS/1-console-during-remote.png" >/dev/null
grab_remote "1-remote-desktop"
echo "   session $SID: $(tgt "loginctl show-session $SID -p Seat -p VTNr -p Remote -p Active -p Class" | tr '\n' ' ')"
check "session is on seat0" "$(prop "$SID" Seat)" "seat0"
check "session is not remote (seat-local)" "$(prop "$SID" Remote)" "no"
check "session is inactive (background)" "$(prop "$SID" Active)" "no"
check "session has its own VT" "$(prop "$SID" VTNr | awk '{print ($1>1)?"yes":"no"}')" "yes"
check "seat0 still shows the greeter" "$(tgt "loginctl show-session \$(loginctl show-seat seat0 -p ActiveSession --value) -p Class --value")" "greeter"
check "only the virtual monitor is in the layout" "$(monitors)" "Meta-0"
check "remote client still connected" "$(cli "pgrep -u \$USER -x xfreerdp3 >/dev/null && echo yes || echo no")" "yes"

grd_pid() { tgt "systemctl show gnome-remote-desktop -p MainPID --value"; }
streamed_since() { tgt "journalctl --user -u gnome-remote-desktop-handover --since @$1 --no-pager | grep -c 'paused to streaming'" | awk '{print ($1>0)?"yes":"no"}'; }
retake() {  # $1 = label; remote logon again and expect a takeover of $SID
  local t0; t0=$(tgt date +%s)
  "$HERE/remote-logon" "$CIP" "$TIP" "$U" "$PW" "$GWU" "$GWP"
  wait_for 45 "[ \"\$(streamed_since $t0)\" = yes ]"
  sleep 3
  grab_remote "$1"
  check "$1: same session taken over (no new session)" "$(graphical_session)" "$SID"
  check "$1: session still in background on seat0" "$(prop "$SID" Active)/$(prop "$SID" Seat)" "no/seat0"
  check "$1: session streamed to the new client" "$(streamed_since "$t0")" "yes"
  check "$1: new client connected" "$(cli "pgrep -u \$USER -x xfreerdp3 >/dev/null && echo yes || echo no")" "yes"
  check "$1: GDM took the takeover path" "$(tgt "journalctl -b --since @$t0 --no-pager | grep -c 'handing session $SID over'" | awk '{print ($1>0)?"yes":"no"}')" "yes"
}

echo "== remote client drops abruptly; session must survive"
cli "pkill -9 -u \$USER -x xfreerdp3"; sleep 8
check "session survives client drop" "$(graphical_session)/$(prop "$SID" Active)" "$SID/no"

echo "== remote logon again after the drop"
retake "2-retake-after-drop"

echo "== remote client goes away mid-handover (redirected reconnect blocked -> handover aborted)"
GRD=$(grd_pid); t0=$(tgt date +%s)
cli "pkill -u \$USER -x xfreerdp3; pkill -u \$USER -x Xvfb; sleep 1; (Xvfb :77 -screen 0 1600x900x24 >/dev/null 2>&1 &); sleep 1; (DISPLAY=:77 setsid xfreerdp3 /v:$TIP /u:$GWU /p:'$GWP' /cert:ignore /size:1600x900 </dev/null >/tmp/gremote.log 2>&1 &); sleep 15; export DISPLAY=:77; xdotool key Return; sleep 2; xdotool type --delay 60 '$PW'; sudo iptables -I OUTPUT -p tcp -d $TIP --dport 3389 --syn -j REJECT; xdotool key Return"
wait_for 60 "tgt \"journalctl -b --since @$t0 --no-pager | grep -q 'Aborting handover'\""
cli "sudo iptables -D OUTPUT -p tcp -d $TIP --dport 3389 --syn -j REJECT; pkill -u \$USER -x xfreerdp3"
check "handover was aborted" "$(tgt "journalctl -b --since @$t0 --no-pager | grep -c 'Aborting handover'" | awk '{print ($1>0)?"yes":"no"}')" "yes"
check "session survives aborted handover" "$(graphical_session)/$(prop "$SID" Active)" "$SID/no"

echo "== remote logon again after the aborted handover"
retake "3-retake-after-abort"
check "system gnome-remote-desktop did not crash" "$(grd_pid)" "$GRD"

echo "== remote works in the session"
tgt "pkill -u \$USER -f '^/usr/libexec/gnome-initial-setup'; echo 'SESSION MARKER: background' > ~/marker.txt; systemd-run --user --quiet --unit=marker-editor gnome-text-editor ~/marker.txt"
sleep 5
cli "export DISPLAY=:77; xdotool mousemove 200 300 click 1; sleep 1; xdotool key ctrl+End; xdotool type --delay 50 ' remote-bg'; xdotool key ctrl+s"
wait_for 8 "[ \"\$(tgt grep -c remote-bg ~/marker.txt)\" = 1 ]" || cli "export DISPLAY=:77; xdotool key ctrl+s"
sleep 2; grab_remote "4-remote-after-typing"
check "remote input reached the session" "$(tgt "grep -c remote-bg ~/marker.txt")" "1"

echo "== local login at seat0 takes the background session"
virsh send-key "$DOM" KEY_ESC >/dev/null; sleep 1
virsh send-key "$DOM" KEY_ENTER >/dev/null; sleep 2
"$HERE/vm-type" "$DOM" "$PW" --enter
wait_for 30 "[ \"\$(prop $SID Active)\" = yes ]"
sleep 6
virsh screenshot "$DOM" "$SHOTS/5-console-reclaimed.png" >/dev/null
check "same session now active on seat0" "$(prop "$SID" Active)" "yes"
check "still only one graphical session" "$(graphical_session)" "$SID"
check "physical monitor restored" "$(monitors)" "Virtual-1"
check "remote client disconnected" "$(cli "pgrep -u \$USER -x xfreerdp3 >/dev/null && echo running || echo exited")" "exited"
check "remote told it was logged off" "$(cli "grep -c ERRINFO_LOGOFF_BY_USER /tmp/gremote.log" | awk '{print ($1>0)?"yes":"no"}')" "yes"

echo "== $pass passed, $fail failed so far; running $EXTRA normal takeover cycles on this session"
res=0; [ "$fail" -eq 0 ] || res=1
if [ "$EXTRA" -gt 0 ]; then "$HERE/gnome-e2e.sh" "$DOM" "$TIP" "$CIP" "$U" "$PW" "$GWU" "$GWP" "$EXTRA" || res=1; fi
exit $res
