# Local ⇄ RDP desktop session handoff (Ubuntu 24.04)

Patches for mutter, gdm3 and gnome-remote-desktop that hand the real GNOME Wayland session on the physical
seat to a Remote Login RDP client and back, Windows-style. A remote logon locks the console onto the GDM
greeter and takes over the session; logging in locally takes it back and disconnects the remote client.

## How it works

| Event | What happens |
|---|---|
| Remote RDP logon (system gnome-remote-desktop on :3389, gateway credentials) and user login at the remote GDM screen | GDM re-authenticates the user against their **existing seat0 session**. It switches seat0 to a login screen and waits until the session is inactive (mutter releases KMS and local input). It then unlocks the session and hands its remote id to gnome-remote-desktop, which redirects the client to the handover daemon inside that session. That daemon streams a virtual monitor, and the virtual monitor is the whole desktop while physical outputs are hidden. |
| While remote | Console shows only the GDM greeter; local keyboard/mouse only reach the greeter; sleep/idle is inhibited |
| Local login at the seat0 greeter | GDM switches back to the session (stock reauth path). The session becomes active, mutter restores the physical outputs, and the handover daemon disconnects the client with `ERRINFO_LOGOFF_BY_USER` |
| Remote logon again | Takeover repeats (RemoteId change path) |
| Remote logon while the user has **no** session | GDM starts the session **in the background on seat0**: it gets its own VT, GDM doesn't switch to it, and it is not marked remote. The console stays on the greeter, the session goes straight to the remote client, and mutter starts paused. It is then an ordinary local session: a local login takes it over, and later remote logons take it back. |

Enabled by `RemoteLoginTakeover=true` in `[daemon]` of `/etc/gdm3/custom.conf` (default false). With it off,
behaviour is stock: the "Session Already Running" dialog when a local session exists, and a seatless headless
session when none does. **GDM reads `custom.conf` only at startup:** restart gdm (or reboot) after changing it.
`setup-gnome-handoff.sh` does this, and `test/check-gdm-config` verifies it.

### Patches (`patches/<pkg>/` series; `patches/<pkg>-rdp-session-handoff.patch` combined)
- **mutter**
  - `renderer`: pausing a session (inactive on its seat) no longer stops the frame clocks of virtual-monitor views.
  - `monitor-manager`: while paused, physical monitors are left out of the layout if virtual monitors exist.
  - `launcher`: syncs the real logind Active state after startup, so a session started in the background is paused
    and later resumes correctly.
  - `eis`: fixes an upstream double close of the libeis fd. With handoff timing it crashed gnome-shell on reclaim
    (libudev `safe_close` abort).
- **gdm3**
  - `RemoteLoginTakeover` option. The remote greeter may re-authenticate a local seat session; GDM then switches
    seat0 to the greeter, waits for the session to go inactive, unlocks it, and exports `RemoteDisplay` (RemoteId,
    SessionId) on its `GdmLocalDisplay`.
  - Background seat0 sessions for remote logins with no existing session: a new worker method `SetSessionSeat`
    (seat0, local, no `PAM_RHOST`, `XDG_SEAT`), and `GdmSession` background mode (`LOGIND_MANAGED`, so a new VT
    that GDM doesn't jump to).
  - `switch_to_compatible_user_session()` guard: never activate or unlock an incompatible session.
  - Quiet remote display factory.
- **gnome-remote-desktop**
  - Handover daemon in local seat sessions: it waits for a takeover instead of giving up, refuses clients while the
    session is active, disconnects the client when the session is reclaimed, holds a sleep inhibitor while a client
    is attached, and never logs out a local session.
  - System daemon: follows RemoteId changes on late-known displays.
  - Fixes an upstream `GVariant` double unref.
  - Fixes a use-after-free in the system daemon. After a handover was aborted (client went away mid-handover), the
    next remote logon to the same session crashed the daemon.

### Build, install, configure
```
# in an Ubuntu 24.04 build machine with deb-src enabled and build-deps installed:
./build-packages.sh patches                    # -> ~/build/<pkg>-src/*.deb (+rdphandoff1)
sudo apt install ./mutter-src/{libmutter-14-0,mutter-common,mutter-common-bin,gir1.2-mutter-14}_*.deb \
                 ./gdm3-src/{gdm3,libgdm1,gir1.2-gdm-1.0}_*.deb ./gnome-remote-desktop-src/gnome-remote-desktop_*.deb
sudo apt-mark hold libmutter-14-0 mutter-common mutter-common-bin gir1.2-mutter-14 gdm3 libgdm1 gir1.2-gdm-1.0 gnome-remote-desktop
sudo ./setup-gnome-handoff.sh <rdp-gateway-user> <rdp-gateway-password>   # then reboot
```
RDP clients connect to port 3389 with the gateway credentials, then log in as themselves on the remote GDM screen.
The client must support server redirection (mstsc, FreeRDP 3, Remmina) and the RDP Graphics Pipeline (GFX).
gnome-remote-desktop 46 drops clients without GFX ("Client did not advertise support for the Graphics Pipeline"). In
Remmina, set the colour depth to one of the "GFX" options.

### Tests (VMs only)
`test/gnome-prepare.sh` reboots the target and logs in locally via `virsh send-key`. `test/gnome-e2e.sh` then runs N
remote-takeover and local-reclaim cycles. It checks seat/session state, monitor layout (DisplayConfig), the sleep
inhibitor, streaming, remote vs physical input (via a saved file), and the remote disconnect reason.
Result: 61/61 over 5 cycles. `test/gnome-e2e-background.sh` starts from a boot with no local session: a remote logon
creates the background seat0 session. It then checks the session survives an abrupt client drop and an aborted
handover (redirected reconnect blocked with iptables on the client VM) and is taken over again after each. The console
then takes it over, and N normal cycles follow (53/53 with 2 cycles). Also checked by hand: a locked session is unlocked for the remote user, the stock dialog
appears with the option off, and stock headless remote login works with no local session.

### Known limitations
- Background seat0 sessions need a graphical seat0 with VTs. Otherwise GDM falls back to the stock headless session.
- A background session takes up a VT on seat0 for as long as it runs, like any other logged-in session.
- The first remote session after boot occasionally drops one key chord (seen once: a Ctrl+S didn't register).
- The Ubuntu Dock extension logs a harmless `g_signal_connect_object` assertion on each monitor layout change.
- Tested with virtio-gpu (no 3D). Rendering on the card fd after DRM master is dropped should be checked on real GPUs,
  especially NVIDIA.
- The mutter DisplayConfig `GetResources` legacy call still lists physical outputs while hidden; `GetCurrentState` is
  consistent.
