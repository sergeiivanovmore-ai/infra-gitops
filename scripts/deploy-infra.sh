#!/bin/bash
# Deploy infrastructure from Git to running containers.
# This is the ONLY command GitHub Actions can run on the VPS.
set -euo pipefail

REPO_DIR="/opt/infra-gitops"
LOG_FILE="/var/log/infra-deploy.log"

exec >> "$LOG_FILE" 2>&1
echo "=== Deploy started at $(date -Iseconds) ==="

cd "$REPO_DIR"
git fetch origin main
git reset --hard origin/main

# Синхронизация Hermes-профилей (только авторские файлы)
rsync -a --delete \
  --exclude='memories/' --exclude='sessions/' --exclude='logs/' \
  --exclude='state.db*' --exclude='.env' --exclude='auth.json' \
  --exclude='workspace/' --exclude='cron/output/' \
  --exclude='skills/' \
  "$REPO_DIR/hermes-gateway/" /opt/docker/hermes/data/

rsync -a --delete \
  --exclude='memories/' --exclude='sessions/' --exclude='logs/' \
  --exclude='state.db*' --exclude='.env' --exclude='auth.json' \
  --exclude='workspace/' --exclude='cron/output/' \
  --exclude='skills/' \
  "$REPO_DIR/hermes-sysadmin/" /opt/docker/hermes-sysadmin/data/

# Skills — только кастомные (bundled и marketplace не трогаем)
rsync -a "$REPO_DIR/hermes-gateway/skills/" /opt/docker/hermes/data/skills/ 2>/dev/null || true

# DSH: 4 файла
cp "$REPO_DIR/dsh/package.json"        /opt/docker/dsh/data/profiles/web/
cp "$REPO_DIR/dsh/pnpm-lock.yaml"      /opt/docker/dsh/data/profiles/web/
cp "$REPO_DIR/dsh/pnpm-workspace.yaml" /opt/docker/dsh/data/profiles/web/
[ -f "$REPO_DIR/dsh/cordis.patch.yml" ] && \
  cp "$REPO_DIR/dsh/cordis.patch.yml"  /opt/docker/dsh/data/profiles/web/

# Владельцы
chown -R 10000:10000 /opt/docker/hermes/data /opt/docker/hermes-sysadmin/data
chown -R 10001:10001 /opt/docker/dsh/data/profiles/web

# Перезапуск
cd /opt/docker/hermes && docker compose up -d
cd /opt/docker/hermes-sysadmin && docker compose up -d
cd /opt/docker/dsh && docker compose up -d

echo "=== Deploy completed at $(date -Iseconds) ==="
