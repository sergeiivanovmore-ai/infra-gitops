#!/bin/bash
# Deploy infrastructure from Git to running containers.
# Runs as root via sudo (forced command). Copies only repo-managed files.
set -euo pipefail

REPO_DIR="/opt/infra-gitops"
LOG_FILE="/var/log/infra-deploy.log"

exec >> "$LOG_FILE" 2>&1

# ── Проверка конфликта хостовых портов между compose-файлами ────────────────
# Хостовые порты задаются в нескольких файлах docker/docker-compose.*.yml, и два
# файла легко могут занять один порт: так почти случилось, когда work получил
# 8642/9119, уже занятые gateway. Проверяем до запуска compose, иначе второй
# docker compose up -d упадёт на занятом порту уже после частичного применения.
check_no_port_conflicts() {
  local dir="$REPO_DIR/docker" conflicts
  # Шаблон ловит "127.0.0.1:8641:8642" и "3080:3080". Порты, заданные через
  # переменную (${DSH_WEB_PORT:-3080}), не разбираются: их значение известно
  # только на хосте, и подставлять сюда догадку нельзя.
  conflicts=$(grep -H -E '^[[:space:]]+-[[:space:]]*"[0-9.]+:[0-9]+:[0-9]+"' \
      "$dir"/docker-compose.*.yml 2>/dev/null \
    | sed -E 's#^.*/([^/]+\.yml):[[:space:]]+-[[:space:]]*"[0-9.]*:([0-9]+):[0-9]+".*#\2 \1#' \
    | sort | awk '{seen[$1]=seen[$1]" "$2; n[$1]++} END {for (p in n) if (n[p]>1) printf "порт %s занят:%s\n", p, seen[p]}') || true
  if [ -n "$conflicts" ]; then
    echo "ОШИБКА: один хостовый порт занят несколькими compose-файлами:"
    echo "$conflicts"
    echo "Разведите порты в docker/docker-compose.*.yml и запустите деплой снова."
    return 1
  fi
  echo "  порты: конфликтов между compose-файлами нет"
  return 0
}

check_no_port_conflicts


# ── Для агента: копия лога ЭТОГО прогона в bind hermes-sysadmin ──────────────
# Агент читает результат деплоя сам: без docker exec и без ручного tail.
# trap на EXIT — копия делается на ЛЮБОМ выходе: успех, провал аудит-гейта,
# провал nginx -t (именно эти случаи важнее всего).
DEPLOY_RUN_OFFSET=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
DEPLOY_LOG_COPY="/opt/docker/hermes-sysadmin/data/logs/deploy-last.log"
copy_deploy_log() {
  mkdir -p "/opt/docker/hermes-sysadmin/data/logs" 2>/dev/null || return 0
  tail -c +$(( ${DEPLOY_RUN_OFFSET:-0} + 1 )) "$LOG_FILE" > "$DEPLOY_LOG_COPY.tmp" 2>/dev/null || return 0
  mv -f "$DEPLOY_LOG_COPY.tmp" "$DEPLOY_LOG_COPY" 2>/dev/null || return 0
  chmod 644 "$DEPLOY_LOG_COPY" 2>/dev/null || true
}
trap copy_deploy_log EXIT


# ── AGENTS_DISABLED_BLOCK_V1: управление standalone-агентами ──────────────────────
# Если файл /opt/docker/hermes/.agents_disabled существует —
# gateway, sysadmin и dsh не поднимаются. Удалить файл — вернутся
# при следующем деплое. Управление на хосте, без PR.
AGENTS_ENABLED=1
if [ -f /opt/docker/hermes/.agents_disabled ]; then
  AGENTS_ENABLED=0
  echo "  AGENTS_DISABLED: standalone agents will not be started"
fi

# --- agent_recreate_ok: обновлять агента, даже когда глобальный флаг выключен ---
# Раньше правка compose для агента доезжала на диск и не применялась: блок стоял
# под AGENTS_ENABLED, поэтому контейнер не пересоздавался. Теперь файлы
# обновляются всегда, а контейнер пересоздаётся, только если он УЖЕ запущен:
# намеренно остановленного агента деплой не воскрешает.
agent_running() {
  [ "$(docker inspect "$1" --format '{{.State.Running}}' 2>/dev/null)" = "true" ]
}

# --- compose_changed / compose_stamp_save: пересоздавать только по делу -------
# Метка хранится рядом с compose, в файле .deploy.stamp. Нет метки — считаем,
# что compose изменился: лишнее пересоздание один раз безопаснее пропуска.
compose_changed() {
  local dir="$1" cur old
  cur=$(md5sum "$dir/docker-compose.yml" 2>/dev/null | cut -d' ' -f1)
  old=$(cat "$dir/.deploy.stamp" 2>/dev/null || echo "")
  [ -n "$cur" ] && [ "$cur" != "$old" ]
}

compose_stamp_save() {
  md5sum "$1/docker-compose.yml" 2>/dev/null | cut -d' ' -f1 > "$1/.deploy.stamp" 2>/dev/null || true
}

# agent_recreate_ok <container>
agent_recreate_ok() {
  local ctr="$1"
  if [ "${AGENTS_ENABLED:-1}" = "1" ]; then return 0; fi
  if agent_running "$ctr"; then
    echo "  $ctr: контейнер запущен, обновляю несмотря на AGENTS_DISABLED"
    return 0
  fi
  echo "  $ctr: не запущен и агенты отключены, пропуск"
  return 1
}

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

if [ -d "$REPO_DIR/agents/hermes-gateway/skills" ]; then
  rsync -a "$REPO_DIR/agents/hermes-gateway/skills/" "$GW_DST/skills/" 2>/dev/null && \
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

if [ -d "$REPO_DIR/agents/hermes-sysadmin/skills" ]; then
  rsync -a "$REPO_DIR/agents/hermes-sysadmin/skills/" "$SA_DST/skills/" 2>/dev/null && \
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
if { [ "$AGENTS_ENABLED" = "1" ] || agent_running hermes-gateway; } && ! docker exec hermes-gateway test -x /opt/data/bin/tirith 2>/dev/null; then
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
if agent_recreate_ok hermes-gateway; then
  if compose_changed /opt/docker/hermes; then
    cd /opt/docker/hermes && docker compose up -d --force-recreate
    compose_stamp_save /opt/docker/hermes
  else
    echo "  hermes-gateway: compose без изменений — пересоздание не требуется"
  fi
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

if agent_recreate_ok hermes-sysadmin; then
  cd /opt/docker/hermes-sysadmin && docker compose up -d
fi
# ── dsh: следует за репозиторием, даже когда standalone-агенты отключены ──
# Раньше блок был под AGENTS_ENABLED, из-за чего правки compose (например новые
# read-only монтирования) приезжали на диск и НЕ применялись: контейнер не
# пересоздавался. Пересоздаём только при реальном изменении файлов — лишних
# рестартов нет. Заморозить dsh отдельно: файл /opt/docker/dsh/.dsh_disabled.
if [ -f /opt/docker/dsh/.dsh_disabled ]; then
  echo "  skipped: dsh (.dsh_disabled)"
else
  DSH_COMPOSE="/opt/docker/dsh/docker-compose.yml"
  DSH_DOCKERFILE="/opt/docker/dsh/Dockerfile.dsh"
  DSH_STAMP="/opt/docker/dsh/.deploy.stamp"
  dsh_compose_sum=$(md5sum "$DSH_COMPOSE" 2>/dev/null | cut -d' ' -f1)
  dsh_dockerfile_sum=$(md5sum "$DSH_DOCKERFILE" 2>/dev/null | cut -d' ' -f1)
  dsh_stamp_new="compose=$dsh_compose_sum dockerfile=$dsh_dockerfile_sum"
  dsh_stamp_old=$(cat "$DSH_STAMP" 2>/dev/null || echo "")
  if [ -z "$dsh_stamp_old" ]; then
    printf '%s\n' "$dsh_stamp_new" > "$DSH_STAMP"
    echo "  dsh: отпечаток конфигов записан (базовый), пересоздание не требуется"
  elif [ "$dsh_stamp_new" = "$dsh_stamp_old" ]; then
    echo "  dsh: конфиги не менялись — пересоздание не требуется"
  else
    dsh_build_flag=""
    if [ "${dsh_stamp_old#*dockerfile=}" != "${dsh_stamp_new#*dockerfile=}" ]; then
      dsh_build_flag="--build"
      echo "  dsh: Dockerfile изменился — с пересборкой образа"
    fi
    if (cd /opt/docker/dsh && docker compose up -d $dsh_build_flag); then
      printf '%s\n' "$dsh_stamp_new" > "$DSH_STAMP"
      echo "  dsh: пересоздан (следует за репозиторием)"
    else
      echo "  ERROR: dsh не пересоздан (compose up failed)" >&2
    fi
  fi
fi

# ── hermes-orchestrator ──────────────────────────────────────────────────────
if agent_recreate_ok hermes-orchestrator; then
  mkdir -p /opt/docker/hermes-orchestrator
  cp -f "$REPO_DIR/docker/docker-compose.orchestrator.yml" /opt/docker/hermes-orchestrator/docker-compose.yml
  echo "  copied: docker-compose.orchestrator.yml -> /opt/docker/hermes-orchestrator/"
  if [ ! -f /opt/docker/hermes-orchestrator/data/.env ]; then
    echo "  SKIP: нет /opt/docker/hermes-orchestrator/data/.env — пересоздание пропущено, чтобы агент не поднялся без переменных" >&2
  elif ! docker network inspect hermes-net >/dev/null 2>&1 || ! docker network inspect mcp-network >/dev/null 2>&1; then
    echo "  SKIP: нет внешней сети hermes-net или mcp-network — compose упрётся в неё" >&2
  else
    cd /opt/docker/hermes-orchestrator
    if compose_changed /opt/docker/hermes-orchestrator; then
      docker compose up -d --force-recreate
      compose_stamp_save /opt/docker/hermes-orchestrator
      echo "  hermes-orchestrator: пересоздан"
    else
      docker compose up -d
      echo "  hermes-orchestrator: compose без изменений — пересоздание не требуется"
    fi
  fi
fi

# ── hermes-work ──────────────────────────────────────────────────────
if agent_recreate_ok hermes-work; then
  mkdir -p /opt/docker/hermes-work
  cp -f "$REPO_DIR/docker/docker-compose.work.yml" /opt/docker/hermes-work/docker-compose.yml
  echo "  copied: docker-compose.work.yml -> /opt/docker/hermes-work/"
  if [ ! -f /opt/docker/hermes-work/data/.env ]; then
    echo "  SKIP: нет /opt/docker/hermes-work/data/.env — пересоздание пропущено, чтобы агент не поднялся без переменных" >&2
  elif ! docker network inspect hermes-net >/dev/null 2>&1 || ! docker network inspect mcp-network >/dev/null 2>&1; then
    echo "  SKIP: нет внешней сети hermes-net или mcp-network — compose упрётся в неё" >&2
  else
    cd /opt/docker/hermes-work
    if compose_changed /opt/docker/hermes-work; then
      docker compose up -d --force-recreate
      compose_stamp_save /opt/docker/hermes-work
      echo "  hermes-work: пересоздан"
    else
      docker compose up -d
      echo "  hermes-work: compose без изменений — пересоздание не требуется"
    fi
  fi
fi

# ================================================================
# cron: часовой синк состояния агентов
# ================================================================
# Синк ходит в приватный hermes-agent-state от root: токен лежит в
# /root/.github-agent-state-token (600 root:root). В cron окружение урезано,
# поэтому PATH задаётся явно, иначе git и rsync не найдутся.
CRON_FILE=/etc/cron.d/agent-state-sync
CRON_LINE='0 * * * * root /opt/infra-gitops/scripts/sync-agent-state.sh >> /var/log/sync-agent-state.log 2>&1'
if ! grep -qF "$CRON_LINE" "$CRON_FILE" 2>/dev/null; then
  {
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "SHELL=/bin/bash"
    echo "$CRON_LINE"
  } > "$CRON_FILE"
  chmod 644 "$CRON_FILE"
  echo "  cron: задача agent-state-sync установлена"
else
  echo "  cron: задача agent-state-sync уже на месте"
fi
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null; then
    echo "  cron: демон активен"
  else
    echo "  WARN: cron-демон не активен — синк состояния запускаться не будет"
  fi
fi

# ================================================================
# cron: ночной бэкап секретов в R2
# ================================================================
# Бэкап ходит в R2 от root: пароль restic в /root/.restic-password, ключи S3 в
# /root/.config/restic/credentials (оба 600 root:root). В cron окружение урезано,
# поэтому PATH задаётся явно, иначе restic не найдётся.
SECRETS_CRON_FILE=/etc/cron.d/secrets-backup
SECRETS_CRON_LINE='30 3 * * * root /opt/infra-gitops/scripts/backup-secrets.sh --yes >> /var/log/backup-secrets.log 2>&1'
if ! grep -qF "$SECRETS_CRON_LINE" "$SECRETS_CRON_FILE" 2>/dev/null; then
  {
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "SHELL=/bin/bash"
    echo "$SECRETS_CRON_LINE"
  } > "$SECRETS_CRON_FILE"
  chmod 644 "$SECRETS_CRON_FILE"
  echo "  cron: задача secrets-backup установлена"
else
  echo "  cron: задача secrets-backup уже на месте"
fi

# ================================================================
# reverse-proxy (nginx-proxy): конфиги из репо
# ================================================================
mkdir -p /opt/docker/reverse-proxy/conf.d
cp -f "$REPO_DIR/reverse-proxy/conf.d/"*.conf /opt/docker/reverse-proxy/conf.d/
echo "  copied: reverse-proxy/conf.d/*.conf -> /opt/docker/reverse-proxy/conf.d/"

# ── Сверка conf.d с репо: файлы, которых нет в репозитории, уводим в бэкап ──
# Репо — единственный источник истины: «удалил из репо» действительно означает удалено.
CONF_DIR="/opt/docker/reverse-proxy/conf.d"
CONF_BACKUP="/opt/docker/backups/reverse-proxy-conf"
mkdir -p "$CONF_BACKUP"
for f in "$CONF_DIR"/*.conf; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  if [ ! -f "$REPO_DIR/reverse-proxy/conf.d/$b" ]; then
    mv -f "$f" "$CONF_BACKUP/$b.retired-$(date +%Y%m%d-%H%M%S)"
    echo "  retired (нет в репо): $b -> $CONF_BACKUP/"
  fi
done


# ── Compose reverse-proxy: тоже из репо (порт, монтирования, healthcheck) ──
# Пересоздание — С АВТО-ОТКАТОМ. 2026-10-23 ingress лёг именно здесь: контейнер
# пересоздался без ручно подключённой сети hermes-net, nginx умер на резолве
# апстримов и ушёл в цикл рестарта. Поэтому перед up -d сохраняем и файл, и
# РАНТАЙМ-сети контейнера, а после проверяем, что nginx реально принимает
# конфиг. Не принимает — возвращаем прежний compose, пересоздаём обратно,
# переподключаем прежние сети. Порядок: файл -> проверка -> откат.
RP_COMPOSE_SRC="$REPO_DIR/reverse-proxy/docker-compose.yml"
RP_COMPOSE_DST="/opt/docker/reverse-proxy/docker-compose.yml"
RP_BACKUP_DIR="/opt/docker/backups/reverse-proxy-conf"
if [ -f "$RP_COMPOSE_SRC" ]; then
  mkdir -p "$RP_BACKUP_DIR"
  RP_PREV="$RP_BACKUP_DIR/docker-compose.yml.prev"
  if [ -f "$RP_COMPOSE_DST" ]; then
    cp -a "$RP_COMPOSE_DST" "$RP_PREV"
  fi
  cp -f "$RP_COMPOSE_SRC" "$RP_COMPOSE_DST"
  echo "  copied: reverse-proxy/docker-compose.yml -> /opt/docker/reverse-proxy/"
  RP_STAMP="/opt/docker/reverse-proxy/.deploy.stamp"
  rp_sum_new=$(md5sum "$RP_COMPOSE_DST" 2>/dev/null | cut -d' ' -f1)
  rp_sum_old=$(cat "$RP_STAMP" 2>/dev/null || echo "")
  rp_health=$(docker inspect nginx-proxy --format '{{if .Config.Healthcheck}}{{.Config.Healthcheck.Test}}{{end}}' 2>/dev/null || echo "")
  if [ "$rp_sum_new" = "$rp_sum_old" ] && [ -n "$rp_health" ]; then
    echo "  nginx-proxy: compose без изменений, healthcheck на месте"
  elif ! (cd /opt/docker/reverse-proxy && docker compose config -q); then
    echo "  ERROR: compose nginx-proxy невалиден — пересоздание пропущено" >&2
    exit 1
  else
    rp_nets_before=$(docker inspect nginx-proxy --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || echo "")
    echo "  nginx-proxy: пересоздаю; сети до правки: ${rp_nets_before:-нет}"
    rp_ok=0
    if (cd /opt/docker/reverse-proxy && docker compose up -d); then
      for _ in $(seq 1 20); do
        sleep 2
        if docker exec nginx-proxy nginx -t >/dev/null 2>&1; then rp_ok=1; break; fi
      done
    fi
    if [ "$rp_ok" = "1" ]; then
      printf '%s\n' "$rp_sum_new" > "$RP_STAMP"
      echo "  nginx-proxy: пересоздан, конфиг принимается"
    else
      echo "  ERROR: nginx-proxy не принимает конфиг после пересоздания — АВТО-ОТКАТ" >&2
      if [ -f "$RP_PREV" ]; then
        cp -a "$RP_PREV" "$RP_COMPOSE_DST"
        echo "  откат: возвращён прежний compose"
        (cd /opt/docker/reverse-proxy && docker compose up -d) || echo "  ERROR: пересоздание по откату не удалось" >&2
      else
        echo "  откат: прежнего compose нет — чинить руками" >&2
      fi
      for _ in 1 2 3; do
        for net in $rp_nets_before; do
          docker network connect "$net" nginx-proxy 2>/dev/null || true
        done
        sleep 2
        rp_nets_now=$(docker inspect nginx-proxy --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || echo "")
        rp_all=1
        for net in $rp_nets_before; do
          echo "$rp_nets_now" | grep -qw "$net" || rp_all=0
        done
        if [ "$rp_all" = "1" ]; then break; fi
        echo "  откат: сетей всё ещё нет ($rp_nets_now) — перезапускаю контейнер"
        docker restart nginx-proxy >/dev/null 2>&1 || true
        sleep 3
      done
      sleep 2
      if docker exec nginx-proxy nginx -t >/dev/null 2>&1; then
        echo "  откат: nginx снова принимает конфиг, ingress восстановлен" >&2
      else
        echo "  ERROR: откат НЕ ПОМОГ — нужен человек" >&2
      fi
      exit 1
    fi
  fi
fi

# ================================================================

# ================================================================
# nginx reload — ПОСЛЕ старта всех сервисов
# ================================================================
sleep 5
if docker exec nginx-proxy nginx -t; then
  docker exec nginx-proxy nginx -s reload
  echo "  nginx: конфиг проверен, reload выполнен"
else
  echo "  ERROR: nginx -t FAILED — конфигурация НЕ применена (nginx работает со старой)" >&2
  echo "  ERROR: смотрите вывод nginx -t выше — там файл-виновник" >&2
  exit 1
fi

echo "=== Deploy completed at $(date -Iseconds) ==="
# ================================================================
# Публикатор из outbox агента — только режим ПЛАНА
# ================================================================
# Агент не может выйти на хост сам: единственный вход закреплён за этим деплоем.
# Поэтому заявки агента обрабатывает деплой, и всегда в режиме плана: строка
# --yes здесь не передаётся никогда, то есть обойти ревью и удалить что-либо
# через этот вызов невозможно. Ошибка публикатора деплой не ломает.
PUB_ENTRY=/opt/infra-gitops/scripts/ops-publish-entry.sh
if [ -f "$PUB_ENTRY" ]; then
  echo "  -- публикатор из outbox (режим плана) --"
  if timeout 300 bash "$PUB_ENTRY"; then
    echo "  публикатор: завершён"
  else
    echo "  публикатор: завершился с ошибкой (деплой не затронут)"
  fi
else
  echo "  публикатор: $PUB_ENTRY не найден — пропуск"
fi
