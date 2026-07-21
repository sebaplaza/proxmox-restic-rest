#!/bin/sh
#
# prune.sh — install a weekly restic forget+prune cron inside the rest-server LXC.
#
# Because the repo is served append-only, clients can't forget/prune — retention
# must run here, directly on the repository on disk. Run this INSIDE the LXC:
#
#   echo '<repo-encryption-password>' > /root/.rpass
#   curl -fsSL https://raw.githubusercontent.com/sebaplaza/proxmox-restic-rest/main/prune.sh | sh
#
# Overridable via env: RESTIC_REPOSITORY (auto-detected), KEEP (retention flags).
#
set -e

apk add --no-cache restic >/dev/null 2>&1 || true

# Auto-detect the on-disk repo (the dir containing restic's "config" file).
REPO="${RESTIC_REPOSITORY:-$(dirname "$(find /mnt/repo -maxdepth 2 -name config -type f | head -n1)")}"
KEEP="${KEEP:---keep-hourly 24 --keep-daily 30 --keep-monthly 12}"

[ -f /root/.rpass ] || { echo "missing /root/.rpass (repo password file)"; exit 1; }

printf '%s\n' \
  '#!/bin/sh' \
  "export RESTIC_REPOSITORY=$REPO" \
  'export RESTIC_PASSWORD_FILE=/root/.rpass' \
  "restic forget --prune $KEEP >> /var/log/restic-prune.log 2>&1" \
  > /etc/periodic/weekly/restic-prune
chmod +x /etc/periodic/weekly/restic-prune

# Ensure busybox crond actually runs the weekly periodic dir.
CRONTAB=/etc/crontabs/root
touch "$CRONTAB"
grep -q '/etc/periodic/weekly' "$CRONTAB" || \
  echo '0 3 * * 0 run-parts /etc/periodic/weekly' >> "$CRONTAB"

rc-update add crond default >/dev/null 2>&1 || true
rc-service crond restart >/dev/null 2>&1 || true

echo "prune cron installed"
echo "  repo:      $REPO"
echo "  retention: $KEEP"
echo "  schedule:  weekly (Sun 03:00), via /etc/periodic/weekly/restic-prune"
