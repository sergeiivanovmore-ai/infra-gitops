#!/bin/bash
# Deploy infrastructure from Git to running containers.
# Runs as root via sudo (forced command). Copies only repo-managed files.
set -euo pipefail

REPO_DIR="/opt/infra-gitops"
LOG_FILE="/var/log/infra-deploy.log"

exec >> "$LOG_FILE" 2>&1
echo "=== Deploy started at $(date -Iseconds) ==="

cd "$REPO_DIR"
git fetch origin main
git reset --hard origin/main

# ---- hermes-gateway ----
GW_SRC="$REPO_DIR/hermes-gateway"
GW_DST="/opt/docker/hermes/data"

for f in SOUL.md config.yaml distribution.yaml AGENTS.md; do
  if [ -f "$GW_SRC/$f" ]; then
    cp -f "$GW_SRC/$f" "$GW_DST/$f"
    echo "  copied: $f -> $GW_DST/"
  fi
done

# cron/jobs.json (только файл)
mkdir -p "$GW_DST/cron"
if [ -f "$GW_SRC/cron/jobs.json" ]; then
  cp -f "$GW_SRC/cron/jobs.json" "$GW_DST/cron/jobs.json"
  echo "  copied: cron/jobs.json"
fi

# кастомные skills (без --delete)
if [ -d "$GW_SRC/skills" ]; then
  rsync -a "$GW_SRC/skills/" "$GW_DST/skills/"
  echo "  synced: skills/"
fi

# ---- hermes-sysadmin ----
SA_SRC="$REPO_DIR/hermes-sysadmin"
SA_DST="/opt/docker/hermes-sysadmin/data"

for f in SOUL.md config.yaml distribution.yaml ARCHITECTURE.md AGENTS.md; do
  if [ -f "$SA_SRC/$f" ]; then
    cp -f "$SA_SRC/$f" "$SA_DST/$f"
    echo "  copied: $f -> $SA_DST/"
  fi
done

mkdir -p "$SA_DST/cron"
if [ -f "$SA_SRC/cron/jobs.json" ]; then
  cp -f "$SA_SRC/cron/jobs.json" "$SA_DST/cron/jobs.json"
  echo "  copied: cron/jobs.json"
fi

# ---- DSH ----
DSH_DST="/opt/docker/dsh/data/profiles/web"
for f in package.json pnpm-lock.yaml pnpm-workspace.yaml cordis.patch.yml cordis.yml; do
  if [ -f "$REPO_DIR/dsh/$f" ]; then
    cp -f "$REPO_DIR/dsh/$f" "$DSH_DST/$f"
    echo "  copied: $f -> $DSH_DST/"
  fi
done

# ---- Ownership ----
chown -R 10000:10000 /opt/docker/hermes/data /opt/docker/hermes-sysadmin/data
chown -R 10001:10001 /opt/docker/dsh/data/profiles/web

# ---- Ensure tirith exists in gateway (copy from sysadmin if missing) ----
if ! docker exec hermes-gateway test -x /opt/data/bin/tirith 2>/dev/null; then
  echo "  restoring tirith in gateway..."
  if docker exec hermes-sysadmin test -x /opt/data/bin/tirith 2>/dev/null; then
    docker cp hermes-sysadmin:/opt/data/bin/tirith /tmp/tirith.gw 2>/dev/null
    docker cp /tmp/tirith.gw hermes-gateway:/opt/data/bin/tirith 2>/dev/null
    docker exec -u root hermes-gateway bash -lc '
      chown 10000:10000 /opt/data/bin/tirith
      chmod 755 /opt/data/bin/tirith
    ' 2>/dev/null
    rm -f /tmp/tirith.gw
  else
    echo "  WARN: tirith missing in both containers"
  fi
fi

# ---- Restart ----
cd /opt/docker/hermes && docker compose up -d
cd /opt/docker/hermes-sysadmin && docker compose up -d
cd /opt/docker/dsh && docker compose up -d

echo "=== Deploy completed at $(date -Iseconds) ==="
