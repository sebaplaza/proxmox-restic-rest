#!/usr/bin/env bash
#
# restic-rest.sh — Deploy a hardened restic REST server in a minimal Alpine LXC.
#
# Run this ON a Proxmox VE host as root. It creates an unprivileged Alpine
# container, bind-mounts a host directory as the repository storage, installs
# restic/rest-server, and runs it in append-only mode behind htpasswd auth.
#
# Append-only means backup clients can add snapshots but cannot delete or
# overwrite existing ones — a stolen or compromised client cannot wipe history.
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/sebaplaza/proxmox-restic-rest/main/restic-rest.sh)"
#
# Every setting can be overridden via environment variables, e.g.:
#   REPO_PATH=/mnt/tank/backups REST_USER=laptop CTID=120 bash restic-rest.sh
#
set -euo pipefail

# ── Configuration (override via env) ─────────────────────────────────────────
CTID="${CTID:-}"                                   # container id (default: next free)
# NB: not HOSTNAME — that name collides with the shell's built-in $HOSTNAME.
CT_HOSTNAME="${CT_HOSTNAME:-restic-rest}"          # container hostname
MEMORY="${MEMORY:-256}"                            # RAM in MB
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"      # storage for the rootfs
ROOTFS_SIZE="${ROOTFS_SIZE:-2}"                    # rootfs size in GB
BRIDGE="${BRIDGE:-vmbr0}"                           # network bridge
REPO_PATH="${REPO_PATH:-/mnt/mergerfs/backups/restic}"  # HOST dir holding the repo
MOUNT_POINT="${MOUNT_POINT:-/mnt/repo}"            # path inside the container
REST_PORT="${REST_PORT:-8000}"                     # port rest-server listens on
REST_USER="${REST_USER:-backup}"                   # htpasswd username
REST_PASS="${REST_PASS:-}"                         # htpasswd password (default: generated)
REST_VERSION="${REST_VERSION:-0.14.0}"             # rest-server release to install
APPEND_ONLY="${APPEND_ONLY:-1}"                    # 1 = append-only (recommended)

# ── Helpers ──────────────────────────────────────────────────────────────────
c_green="\033[0;32m"; c_yellow="\033[0;33m"; c_red="\033[0;31m"; c_reset="\033[0m"
info() { echo -e "${c_green}[+]${c_reset} $*"; }
warn() { echo -e "${c_yellow}[!]${c_reset} $*"; }
die()  { echo -e "${c_red}[x]${c_reset} $*" >&2; exit 1; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Run as root on the Proxmox host."
command -v pct >/dev/null || die "pct not found — is this a Proxmox VE host?"

[ -n "$CTID" ] || CTID="$(pvesh get /cluster/nextid)"
pct status "$CTID" >/dev/null 2>&1 && die "Container $CTID already exists."

# Pick the newest Alpine template already present; download one if none.
TEMPLATE="$(pveam list local 2>/dev/null | awk '/alpine-3/{print $1}' | sort -V | tail -1 || true)"
if [ -z "$TEMPLATE" ]; then
  warn "No Alpine template found locally, downloading the latest…"
  pveam update >/dev/null
  AVAIL="$(pveam available --section system | awk '/alpine-3/{print $2}' | sort -V | tail -1)"
  [ -n "$AVAIL" ] || die "Could not find an Alpine template to download."
  pveam download local "$AVAIL" >/dev/null
  TEMPLATE="local:vztmpl/$AVAIL"
fi
info "Using template: $TEMPLATE"

[ -n "$REST_PASS" ] || REST_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)"

# ── Storage on the host ───────────────────────────────────────────────────────
# Unprivileged containers map root(0) -> 100000 on the host, so the bind-mount
# target must be owned by 100000 for the container to write into it.
info "Preparing repository storage at $REPO_PATH"
mkdir -p "$REPO_PATH"
chown 100000:100000 "$REPO_PATH"

# ── Create the container ──────────────────────────────────────────────────────
info "Creating LXC $CTID ($CT_HOSTNAME)…"
pct create "$CTID" "$TEMPLATE" \
  --hostname "$CT_HOSTNAME" \
  --cores 1 --memory "$MEMORY" --swap "$MEMORY" \
  --rootfs "${ROOTFS_STORAGE}:${ROOTFS_SIZE}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged 1 \
  --mp0 "${REPO_PATH},mp=${MOUNT_POINT}" \
  --onboot 1 --start 1
sleep 8

# ── Install rest-server inside the container ──────────────────────────────────
info "Installing rest-server ${REST_VERSION} inside the container…"
pct exec "$CTID" -- sh -c 'cat > /tmp/install.sh' <<INSTALL
set -e
apk add --no-cache apache2-utils curl >/dev/null
V="${REST_VERSION}"
F="rest-server_\${V}_linux_amd64"
cd /tmp
curl -sLO "https://github.com/restic/rest-server/releases/download/v\${V}/\${F}.tar.gz"
tar xzf "\${F}.tar.gz"
install -m755 "\${F}/rest-server" /usr/local/bin/rest-server
mkdir -p "${MOUNT_POINT}"
htpasswd -bBc "${MOUNT_POINT}/.htpasswd" "${REST_USER}" "${REST_PASS}"
/usr/local/bin/rest-server --version
INSTALL
pct exec "$CTID" -- sh /tmp/install.sh

# ── OpenRC service ────────────────────────────────────────────────────────────
info "Configuring the rest-server service…"
APPEND_FLAG=""; [ "$APPEND_ONLY" = "1" ] && APPEND_FLAG="--append-only"
pct exec "$CTID" -- sh -c 'cat > /etc/init.d/rest-server' <<SERVICE
#!/sbin/openrc-run
command="/usr/local/bin/rest-server"
command_args="--path ${MOUNT_POINT} --listen :${REST_PORT} ${APPEND_FLAG} --private-repos"
command_background=true
pidfile="/run/rest-server.pid"
output_log="/var/log/rest-server.log"
error_log="/var/log/rest-server.log"
SERVICE
pct exec "$CTID" -- sh -c 'chmod +x /etc/init.d/rest-server; rc-update add rest-server default; rc-service rest-server restart'
sleep 2

# ── Report ────────────────────────────────────────────────────────────────────
IP="$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)"
STATUS="$(pct exec "$CTID" -- rc-service rest-server status 2>&1 | tr -d '\n')"

echo
info "Done."
echo    "─────────────────────────────────────────────────────────────"
echo -e "  Container   : ${CTID} (${CT_HOSTNAME})"
echo -e "  Address     : ${IP}:${REST_PORT}"
echo -e "  Storage     : ${REPO_PATH}  ->  ${MOUNT_POINT}"
echo -e "  Append-only : $([ "$APPEND_ONLY" = "1" ] && echo yes || echo no)"
echo -e "  Service     : ${STATUS}"
echo    "─────────────────────────────────────────────────────────────"
echo -e "  Repository URL for restic / Backrest clients:"
echo -e "    ${c_green}rest:http://${REST_USER}:${REST_PASS}@${IP}:${REST_PORT}/${REST_USER}/${c_reset}"
echo -e "  (with --private-repos the path MUST start with the username)"
echo
echo -e "  Initialise it once from a client:"
echo -e "    export RESTIC_REPOSITORY='rest:http://${REST_USER}:${REST_PASS}@${IP}:${REST_PORT}/${REST_USER}/'"
echo -e "    export RESTIC_PASSWORD='<your-encryption-password>'"
echo -e "    restic init"
echo
warn  "Save the credentials above — the password is not stored anywhere else."
