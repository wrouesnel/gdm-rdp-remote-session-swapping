#!/bin/bash
# Reboot the target VM, log in locally at the GDM greeter via the VM keyboard and
# open ~/marker.txt in gnome-text-editor (precondition for gnome-e2e.sh).
# Usage: test/gnome-prepare.sh <domain> <ip> <user> <password> [client-ip]
set -uo pipefail
DOM=$1; IP=$2; U=$3; PW=$4; CIP=${5:-}
HERE=$(cd "$(dirname "$0")" && pwd)
[ -n "$CIP" ] && ssh "$U@$CIP" 'pkill -u $USER -x xfreerdp3; pkill -u $USER -x Xvfb' 2>/dev/null
ssh "$U@$IP" 'sudo rm -f /var/crash/*; sudo reboot' 2>/dev/null
sleep 10
for i in $(seq 1 80); do
  ssh -o ConnectTimeout=2 "$U@$IP" 'loginctl list-sessions --no-legend | grep -q "gdm .*seat0"' 2>/dev/null && break
  sleep 3
done
sleep 8
virsh send-key "$DOM" KEY_ENTER >/dev/null; sleep 2
"$HERE/vm-type" "$DOM" "$PW" --enter
for i in $(seq 1 40); do
  ssh "$U@$IP" "loginctl list-sessions --no-legend | awk '\$3==\"$U\" && \$4==\"seat0\" && \$6==\"active\"' | grep -q ." && break
  sleep 2
done
sleep 15
ssh "$U@$IP" 'pkill -u $USER -f "^/usr/libexec/gnome-initial-setup"; echo "SESSION MARKER: $(date +%T)" > ~/marker.txt; systemd-run --user --quiet --unit=marker-editor gnome-text-editor ~/marker.txt; sleep 4; loginctl list-sessions --no-legend'
