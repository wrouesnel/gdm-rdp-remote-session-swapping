#!/bin/bash
# Configure an Ubuntu noble machine (with the patched mutter/gdm3/gnome-remote-desktop
# packages installed) for local <-> RDP console session handoff. Run as root.
# Usage: setup-gnome-handoff.sh <rdp-gateway-user> <rdp-gateway-password>
set -euo pipefail
GW_USER=${1:?gateway user}; GW_PASS=${2:?gateway password}

# GDM: enable Remote Login and let it take over existing local sessions.
python3 - <<'PY'
import configparser
p = '/etc/gdm3/custom.conf'
c = configparser.ConfigParser(strict=False, interpolation=None)
c.optionxform = str
c.read(p)
if not c.has_section('daemon'):
    c.add_section('daemon')
c.set('daemon', 'RemoteLoginEnable', 'true')
c.set('daemon', 'RemoteLoginTakeover', 'true')
with open(p, 'w') as f:
    c.write(f)
PY

# System gnome-remote-desktop (the RDP listener on :3389 for remote login).
install -d -o gnome-remote-desktop -g gnome-remote-desktop -m 0700 /var/lib/gnome-remote-desktop/.local/share/gnome-remote-desktop
KEY=/var/lib/gnome-remote-desktop/.local/share/gnome-remote-desktop/tls.key
CRT=/var/lib/gnome-remote-desktop/.local/share/gnome-remote-desktop/tls.crt
if [ ! -e "$KEY" ]; then
  openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/CN=$(hostname)" -keyout "$KEY" -out "$CRT" 2>/dev/null
  chown gnome-remote-desktop: "$KEY" "$CRT"
fi
grdctl --system rdp set-tls-key "$KEY"
grdctl --system rdp set-tls-cert "$CRT"
grdctl --system rdp set-credentials "$GW_USER" "$GW_PASS"
grdctl --system rdp enable
systemctl enable --now gnome-remote-desktop.service

# The handover daemon must run in every graphical session, including local ones.
systemctl --global enable gnome-remote-desktop-handover.service

systemctl restart gdm3 || true
grdctl --system status
