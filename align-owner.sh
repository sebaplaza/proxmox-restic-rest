#!/bin/sh
#
# align-owner.sh — remap a rest-server LXC (from this repo) so repository files
# are owned by an existing HOST user (e.g. share-data) instead of the default
# unprivileged mapping (uid 100000).
#
# Run on the Proxmox VE host, as root:
#   CTID=117 OWNER=share-data bash -c "$(curl -fsSL https://raw.githubusercontent.com/sebaplaza/proxmox-restic-rest/main/align-owner.sh)"
#
# It: adds a uid/gid idmap mapping container <uid> -> host <uid>, chowns the
# bind-mounted repo to that owner, and runs rest-server as that user inside.
#
set -e

CTID="${CTID:?set CTID, e.g. CTID=117}"
OWNER="${OWNER:-share-data}"
UID_N="$(id -u "$OWNER")"
GID_N="$(id -g "$OWNER")"
CONF="/etc/pve/lxc/${CTID}.conf"

# Host path of the first bind mount (mp0).
HOSTDIR="$(pct config "$CTID" | sed -n 's/^mp0: \([^,]*\),.*/\1/p')"
[ -n "$HOSTDIR" ] || { echo "no mp0 bind mount on CT $CTID"; exit 1; }

echo "[+] CT $CTID | owner $OWNER ($UID_N:$GID_N) | repo $HOSTDIR"

# Allow root to map the target uid/gid (idempotent).
grep -q "root:${UID_N}:1" /etc/subuid || echo "root:${UID_N}:1" >> /etc/subuid
grep -q "root:${GID_N}:1" /etc/subgid || echo "root:${GID_N}:1" >> /etc/subgid

pct stop "$CTID" 2>/dev/null || true

# Add the idmap once. Pattern mirrors the standard "single-uid passthrough":
#   c[0..UID-1]   -> h[100000..]
#   c[UID]        -> h[UID]           (the passthrough)
#   c[UID+1..]    -> h[100000+UID..]
if ! grep -q "lxc.idmap: u ${UID_N} ${UID_N} 1" "$CONF"; then
  {
    echo "lxc.idmap: u 0 100000 ${UID_N}"
    echo "lxc.idmap: u ${UID_N} ${UID_N} 1"
    echo "lxc.idmap: u $((UID_N+1)) $((100000+UID_N)) $((65536-UID_N-1))"
    echo "lxc.idmap: g 0 100000 ${GID_N}"
    echo "lxc.idmap: g ${GID_N} ${GID_N} 1"
    echo "lxc.idmap: g $((GID_N+1)) $((100000+GID_N)) $((65536-GID_N-1))"
  } >> "$CONF"
  echo "[+] idmap added to $CONF"
else
  echo "[=] idmap already present, skipping"
fi

# Existing repo data -> owned by the target on the host.
echo "[+] chown -R ${UID_N}:${GID_N} $HOSTDIR (may take a moment)"
chown -R "${UID_N}:${GID_N}" "$HOSTDIR"

pct start "$CTID"
sleep 6

# Inside: a user/group with the matching id, and run rest-server as it.
pct exec "$CTID" -- sh -c "addgroup -g ${GID_N} restic 2>/dev/null || true; adduser -D -H -u ${UID_N} -G restic restic 2>/dev/null || true"
pct exec "$CTID" -- sh -c 'grep -q "^command_user=" /etc/init.d/rest-server || sed -i "/^command=/a command_user=\"restic:restic\"" /etc/init.d/rest-server'
# rest-server now runs as the unprivileged user; make its logfile writable by it.
pct exec "$CTID" -- sh -c 'touch /var/log/rest-server.log; chown restic:restic /var/log/rest-server.log'
pct exec "$CTID" -- rc-service rest-server restart
sleep 2

echo "--- host ownership now ---"
stat -c '%u:%g (%U:%G)' "$HOSTDIR"
echo "--- rest-server ---"
pct exec "$CTID" -- rc-service rest-server status
