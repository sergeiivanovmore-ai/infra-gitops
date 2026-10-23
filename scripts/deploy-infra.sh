#!/bin/bash
# Deploy infrastructure from Git to running containers.
# Runs as root via sudo (forced command). Copies only repo-managed files.
set -euo pipefail

REPO_DIR="/opt/infra-gitops"
LOG_FILE="/var/log/infra-deploy.log"

exec >> "$LOG_FILE" 2>&1

# ── AGENTS_DISABLED_BLOCK_V1: управление standalone-агентами ──────────────────────
# Если файл /opt/docker/hermes/.agents_disabled существует —
# gateway, sysadmin и dsh не поднимаются. Удалить файл — вернутся
# при следующем деплое. Управление на хосте, без PR.
AGENTS_ENABLED=1
if [ -f /opt/docker/hermes/.agents_disabled ]; then
  AGENTS_ENABLED=0
  echo "  AGENTS_DISABLED: standalone agents will not be started"
fi

echo "=== Deploy started at $(date -Iseconds) ==="

cd "$REPO_DIR"
git fetch origin main
git reset --hard origin/main

# ── Self-install: обновляем хостовую копию из репо ──────────────
if [ -f "$REPO_DIR/scripts/deploy-infra.sh" ]; then
  # self-install-atomic: cp -f пишет по тому же inode, и bash,
  # читающий этот же файл, ловит рассинхрон → syntax error.
  # mv атомарен — bash продолжает читать старый inode.
  cp -f "$REPO_DIR/scripts/deploy-infra.sh" /usr/local/bin/deploy-infra.sh.new
  chmod 755 /usr/local/bin/deploy-infra.sh.new
  mv -f /usr/local/bin/deploy-infra.sh.new /usr/local/bin/deploy-infra.sh
  # audit-check.sh: та же атомарная подмена, иначе хостовая копия
  # снова разъедется с репо (аудит — это гейт деплоя).
  cp -f "$REPO_DIR/scripts/audit-check.sh" /usr/local/bin/audit-check.sh.new
  chmod 755 /usr/local/bin/audit-check.sh.new
  mv -f /usr/local/bin/audit-check.sh.new /usr/local/bin/audit-check.sh
  echo "  self-install: audit-check.sh updated from repo"

  echo "  self-install: deploy-infra.sh updated from repo (takes effect next deploy)"
fi

/usr/local/bin/audit-check.sh || exit 1

# ================================================================
# hermes-gateway
# ================================================================
cp -f "$REPO_DIR/docker/docker-compose.gateway.yml" /opt/docker/hermes/docker-compose.yml
echo "  copied: docker-compose.gateway.yml -> /opt/docker/hermes/"

GW_SRC="$REPO_DIR/hermes-gateway"
GW_DST="/opt/docker/hermes/data"

for f in SOUL.md config.yaml distribution.yaml AGENTS.md; do
  if [ -f "$GW_SRC/$f" ]; then
    cp -f "$GW_SRC/$f" "$GW_DST/$f"
    echo "  copied: $f -> $GW_DST/"
  fi
done

mkdir -p "$GW_DST/cron"
if [ -f "$GW_SRC/cron/jobs.json" ]; then
  cp -f "$GW_SRC/cron/jobs.json" "$GW_DST/cron/jobs.json"
  echo "  copied: cron/jobs.json"
fi

if [ -d "$GW_SRC/skills" ]; then
  rsync -a "$GW_SRC/skills/" "$GW_DST/skills/" 2>/dev/null && \
    echo "  synced: skills/"
fi

# ================================================================
# hermes-sysadmin
# ================================================================
cp -f "$REPO_DIR/docker/docker-compose.sysadmin.yml" /opt/docker/hermes-sysadmin/docker-compose.yml
echo "  copied: docker-compose.sysadmin.yml -> /opt/docker/hermes-sysadmin/"

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

if [ -d "$SA_SRC/skills" ]; then
  rsync -a "$SA_SRC/skills/" "$SA_DST/skills/" 2>/dev/null && \
    echo "  synced: skills/"
fi

# ================================================================
# DSH
# ================================================================
cp -f "$REPO_DIR/docker/docker-compose.dsh.yml" /opt/docker/dsh/docker-compose.yml
cp -f "$REPO_DIR/docker/Dockerfile.dsh"          /opt/docker/dsh/Dockerfile.dsh
echo "  copied: docker-compose.dsh.yml + Dockerfile.dsh -> /opt/docker/dsh/"

DSH_DST="/opt/docker/dsh/data/profiles/web"
for f in package.json pnpm-lock.yaml pnpm-workspace.yaml cordis.patch.yml cordis.yml; do
  if [ -f "$REPO_DIR/dsh/$f" ]; then
    cp -f "$REPO_DIR/dsh/$f" "$DSH_DST/$f"
    echo "  copied: $f -> $DSH_DST/"
  fi
done

# ── Ownership ДО pnpm install ──────────────────────────────────
# Пользователь dsh (uid 10001) должен иметь право писать в $DSH_DST.
# Если там остались root-овские файлы от прошлого деплоя, pnpm упадёт
# с EACCES при попытке обновить node_modules или lock-файлы.
chown -R 10001:10001 "$DSH_DST"

# ── Установить зависимости DSH из обновлённого package.json ────
# agents-disabled-dsh-guard: пропускаем, если dsh остановлен
if [ "$AGENTS_ENABLED" = "1" ]; then
  echo "  syncing DSH profile web (pnpm install)..."
  if ! docker exec -u dsh dsh sh -c '
        cd /home/dsh/.dsh/profiles/web && \
        pnpm install 2>&1 | tail -3
      '; then
    echo "  ERROR: pnpm install failed in DSH web profile" >&2
  fi
else
  echo "  skipped: DSH pnpm install (agents disabled)"
fi

# ── Очистка устаревшего session cache DSH ──────────────────────
# В session_projcache могут храниться cwd с хост-путями вроде
# /opt/docker, которых нет внутри контейнера. При старте DSH
# восстанавливает последнюю сессию и падает на realpath('/opt/docker'):
#   [dsh-carrot-on-a-stick] workspace attach failed:
#   Error: ENOENT: no such file or directory, realpath '/opt/docker'
# Каталог bind-mounted с хоста (./data:/home/dsh/.dsh в compose),
# поэтому кэш переживает рестарты и переезжает между деплоями.
# Удаляем только JSON-файлы сессий, каталоги и state.db не трогаем.
DSH_SESSIONS="/opt/docker/dsh/data/storages/session_projcache/sessions"
if [ -d "$DSH_SESSIONS" ]; then
  before=$(find "$DSH_SESSIONS" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)
  find "$DSH_SESSIONS" -maxdepth 1 -type f -name '*.json' -delete 2>/dev/null || true
  after=$(find "$DSH_SESSIONS" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)
  echo "  cleaned: DSH session_projcache ($before -> $after files)"
fi

# ── Очистка мёртвых session-директорий ─────────────────────────
# DSH группирует сессии по cwd в /home/dsh/.dsh/sessions/<slug>/,
# где slug -- это cwd с / → - (например --opt-docker-- для /opt/docker).
# Если cwd не существует внутри контейнера, плагин dsh-carrot-on-a-stick
# падает на realpath(cwd):
#   [dsh-carrot-on-a-stick] workspace attach failed:
#   Error: ENOENT: no such file or directory, realpath '/opt/docker'
# Проверяем существование изнутри контейнера (на хосте /opt/docker есть!),
# удаляем только мёртвые папки.
DSH_SESSIONS_ROOT="/opt/docker/dsh/data/sessions"
if [ -d "$DSH_SESSIONS_ROOT" ]; then
  removed=0
  for d in "$DSH_SESSIONS_ROOT"/--*--; do
    [ -e "$d" ] || continue
    name=$(basename "$d")
    rel=${name#--}; rel=${rel%--}
    candidate="/${rel//-//}"
    if ! docker exec dsh test -e "$candidate" 2>/dev/null; then
      rm -rf "$d"
      removed=$((removed + 1))
      echo "  removed dead session dir: $name (cwd=$candidate missing in container)"
    fi
  done
  echo "  cleaned: DSH dead session dirs ($removed removed)"
fi

# ── Повторный chown ────────────────────────────────────────────
# На случай, если pnpm оставил временные файлы с другим владельцем.
chown -R 10001:10001 "$DSH_DST"

# ================================================================
# Ownership
# ================================================================
chown -R 10000:10000 /opt/docker/hermes/data /opt/docker/hermes-sysadmin/data

# ── Normalize gateway .env ─────────────────────────────────────
# Hermes загружает /opt/data/.env с override=True — эти значения
# перебивают env из docker-compose. Отключаем встроенный dashboard,
# иначе gateway уходит в retry-loop:
#   Refusing to bind dashboard to 0.0.0.0 — no auth providers.
GW_ENV="$GW_DST/.env"
if [ -f "$GW_ENV" ]; then
  if grep -q '^HERMES_DASHBOARD=' "$GW_ENV"; then
    sed -i 's/^HERMES_DASHBOARD=.*$/HERMES_DASHBOARD=0/' "$GW_ENV"
  else
    echo 'HERMES_DASHBOARD=0' >> "$GW_ENV"
  fi
  echo "  normalized: HERMES_DASHBOARD=0 in $GW_ENV"
fi

# ================================================================
# Ensure tirith exists in gateway (copy from sysadmin if missing)
# ================================================================
if [ "$AGENTS_ENABLED" = "1" ] && ! docker exec hermes-gateway test -x /opt/data/bin/tirith 2>/dev/null; then
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

# ================================================================
# Restart
# ================================================================
if [ "$AGENTS_ENABLED" = "1" ]; then
  cd /opt/docker/hermes && docker compose up -d --force-recreate
else
  echo "  skipped: hermes-gateway (agents disabled)"
fi

# ── Ensure A2A toolset enabled (runtime state, not in config.yaml) ──
if [ "$AGENTS_ENABLED" = "1" ]; then
  echo "  ensuring a2a toolset for telegram..."
  sleep 5
  docker exec hermes-gateway bash -lc \
    '/opt/hermes/.venv/bin/hermes tools enable a2a --platform telegram' \
    || echo "  WARN: failed to enable a2a toolset (non-fatal)"
fi

if [ "$AGENTS_ENABLED" = "1" ]; then
  cd /opt/docker/hermes-sysadmin && docker compose up -d
fi
if [ "$AGENTS_ENABLED" = "1" ]; then
  cd /opt/docker/dsh && docker compose up -d --build
fi

# ================================================================
# reverse-proxy (nginx-proxy): конфиги из репо
# ================================================================
mkdir -p /opt/docker/reverse-proxy/conf.d
cp -f "$REPO_DIR/reverse-proxy/conf.d/"*.conf /opt/docker/reverse-proxy/conf.d/
echo "  copied: reverse-proxy/conf.d/*.conf -> /opt/docker/reverse-proxy/conf.d/"

# ================================================================
# Hermes Studio
# ================================================================
mkdir -p /opt/docker/hermes-studio/data
cp -f "$REPO_DIR/docker/docker-compose.studio.yml" /opt/docker/hermes-studio/docker-compose.yml
echo "  copied: docker-compose.studio.yml -> /opt/docker/hermes-studio/"
cd /opt/docker/hermes-studio && docker compose up -d

# ================================================================
# nginx reload — ПОСЛЕ старта всех сервисов
# ================================================================
sleep 5
docker exec nginx-proxy nginx -t && docker exec nginx-proxy nginx -s reload || echo "  WARN: nginx reload failed"

echo "=== Deploy completed at $(date -Iseconds) ==="