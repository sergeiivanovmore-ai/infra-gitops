#!/bin/bash
# Deploy pipeline for hermes-gateway & dsh & reverse-proxy & infra-gitops repo.
# Called by:
#   - GitHub Actions (appleboy/ssh-action with SSH key) as root
#   - /etc/cron.d/infra-deploy (direct SSH as root, AUDIT_MODE=off)
# Purpose: apply all pending changes from the infra-gitops repo to the host.
# Design: idempotent, merge-gated (audit-check enforces SHAs come from merged PRs).
set -u

REPO_DIR="/opt/infra-gitops"
AGENTS_DISABLED_FILE="/opt/docker/hermes/.agents_disabled"
DSH_DISABLED_FILE="/opt/docker/dsh/.dsh_disabled"
DSH_STAMP="/opt/docker/dsh/.deploy.stamp"
HAD_ERRORS=0

echo "=== Deploy started at $(date -Iseconds) ==="
echo "  infra-gitops directory: $REPO_DIR"

# ================================================================
# self-install: если deploy-infra.sh или audit-check.sh изменились в
# репозитории (за счёт предыдущего мержа), скопировать их на хост.
# self-install — до любой другой работы, иначе нововведения не применяются.
# cp -f пишет по новому inode, поэтому работающий bash не «съедает» свой
# только что заменённый исполняемый файл: он держал старый дескриптор inode.
# Новый скрипт применится следующим прогоном — и это нормально.
# ================================================================
if [ -f "$REPO_DIR/scripts/deploy-infra.sh" ]; then
  # self-install-atomic: cp -f пишет по тому же inode, и bash,
  # читающий скрипт через descriptor, продолжает работать со старым inode.
  # Тем не менее, mv небезопасен: если bash пролистал вперёд, он может
  # прочитать кусок нового содержимого. Поэтому копируем в .new и rename.
  cp -f "$REPO_DIR/scripts/deploy-infra.sh" /usr/local/bin/deploy-infra.sh.new \
    && mv -f /usr/local/bin/deploy-infra.sh.new /usr/local/bin/deploy-infra.sh \
    && chmod +x /usr/local/bin/deploy-infra.sh
  cp -f "$REPO_DIR/scripts/audit-check.sh" /usr/local/bin/audit-check.sh.new \
    && mv -f /usr/local/bin/audit-check.sh.new /usr/local/bin/audit-check.sh \
    && chmod +x /usr/local/bin/audit-check.sh
  echo "  self-install: audit-check.sh updated from repo"
  echo "  self-install: deploy-infra.sh updated from repo (takes effect next deploy)"
fi

# ================================================================
# Audit
# ================================================================
if [ -x /usr/local/bin/audit-check.sh ]; then
  echo "  audit: starting..."
  /usr/local/bin/audit-check.sh "$REPO_DIR" "$@" || {
    echo "  ERROR: audit-check failed — skipping deploy to prevent unmerged changes" >&2
    echo "=== Deploy aborted at $(date -Iseconds) ==="
    exit 1
  }
  echo "  audit: passed"
fi

# ================================================================
# 1. Reverse-proxy (nginx)
# ================================================================
RP_DIR="$REPO_DIR/reverse-proxy"
RP_TARGET_HOST="/opt/docker/reverse-proxy"
if [ -d "$RP_DIR" ]; then
  mkdir -p "$RP_TARGET_HOST"
  if ! diff -rq "$RP_DIR" "$RP_TARGET_HOST" 2>/dev/null; then
    echo "  nginx-прокси: есть изменения, копирую..."
    cp -r "$RP_DIR/" "$RP_TARGET_HOST/" && echo "  nginx-прокси: файлы скопированы на хост" || {
      echo "  ERROR: nginx-прокси: cp -r вернул ошибку" >&2
      HAD_ERRORS=1
    }
  else
    echo "  nginx-прокси: изменений нет — пропуск"
  fi
fi

# ================================================================
# 2. DSH compose
# ================================================================
DSH_DIR="$REPO_DIR/docker"
DSH_TARGET="/opt/docker/dsh"
if [ -d "$DSH_DIR" ]; then
  mkdir -p "$DSH_TARGET"
  if ! diff -rq "$DSH_DIR" "$DSH_TARGET" 2>/dev/null; then
    echo "  dsh: есть изменения, копирую..."
    cp -r "$DSH_DIR/" "$DSH_TARGET/" && echo "  dsh: файлы скопированы на хост" || {
      echo "  ERROR: dsh: cp -r вернул ошибку" >&2
      HAD_ERRORS=1
    }
  else
    echo "  dsh: изменений нет — пропуск"
  fi
fi

# ================================================================
# 3. Diagnose + publish scripts
# ================================================================
SCRIPTS_SRC="$REPO_DIR/scripts"
SCRIPTS_DST="/opt/docker/hermes-sysadmin/data/scripts"
mkdir -p "$SCRIPTS_DST"
for script in diagnose-infra.sh diagnose.yml; do
  if [ -f "$SCRIPTS_SRC/$script" ]; then
    cp -f "$SCRIPTS_SRC/$script" "$SCRIPTS_DST/$script"
  fi
done

# ================================================================
# 4. Synchronize all non-binary files (excluding docker/ and reverse-proxy/ which are handled separately)
# ================================================================
echo "  синхронизация файлов репозитория..."
rsync -a --delete --exclude='.git/' --exclude='docker/' --exclude='reverse-proxy/' \
  "$REPO_DIR/" /opt/infra-gitops-sync/ 2>/dev/null || true

# ================================================================
# 5. Restart containers
# ================================================================

restart_stack() {
  local prefix="$1" stamp2="$2" dir="$3" dockerfile="$4"
  local compose_file="$dir/docker-compose.yml"
  local pr="$(printf '%s' "$prefix" | tr '[:lower:]' '[:upper:]')"

  if [ ! -f "$compose_file" ]; then
    echo "  [$prefix] compose-файла нет — пропуск"
    return
  fi

  if [ "$prefix" = "dsh" ] && [ -f "$DSH_DISABLED_FILE" ]; then
    echo "  dsh: disabled by $DSH_DISABLED_FILE — пересоздание не будет"
    return
  fi

  local stamp_old=""
  [ -f "$stamp2" ] && stamp_old=$(cat "$stamp2")
  local stamp_new
  stamp_new=$( (cat "$compose_file"; [ -n "$dockerfile" ] && [ -f "$dir/$dockerfile" ] && cat "$dir/$dockerfile") | md5sum | cut -c1-32 )

  if [ "$stamp_old" = "$stamp_new" ]; then
    echo "  [$prefix] отпечаток не изменился — пересоздание не нужно"
    return
  fi

  if ! docker compose -f "$compose_file" config -q 2>/dev/null; then
    echo "  ERROR: [$prefix] compose config -q FAILED — файл невалиден, контейнер не трогаю" >&2
    HAD_ERRORS=1
    return
  fi

  # nginx-proxy: запомнить ручные сети ДО пересоздания (они не объявлены в compose
  # и теряются после up -d). После пересоздания они восстанавливаются.
  local saved_nets=""
  local cont_name=""
  case "$prefix" in
    nginx-proxy) cont_name="nginx-proxy" ;;
    dsh) cont_name="dsh" ;;
  esac
  if [ -n "$cont_name" ]; then
    saved_nets=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$cont_name" 2>/dev/null)
    echo "  [$prefix] сети до правки: $saved_nets"
  fi

  # Сохраняем предыдущую версию compose для возможного отката
  if [ -f "$compose_file" ]; then
    mkdir -p /opt/docker/backups/${prefix}-conf/
    cp -f "$compose_file" "/opt/docker/backups/${prefix}-conf/docker-compose.yml.prev"
  fi

  if [ -n "$dockerfile" ] && [ -f "$dir/$dockerfile" ]; then
    echo "  [$prefix] пересоздаю (изменён compose и/или dockerfile)"
    docker compose -f "$compose_file" up -d --build 2>&1
  else
    echo "  [$prefix] пересоздаю (изменён compose)"
    docker compose -f "$compose_file" up -d 2>&1
  fi

  local rc="$?"
  if [ "$rc" != "0" ]; then
    echo "  ERROR: [$prefix] пересоздание не удалось (rc=$rc)" >&2
    HAD_ERRORS=1
    return
  fi

  # nginx: ждём, пока nginx -t подтвердит, что конфиг принимается
  if [ "$prefix" = "nginx-proxy" ]; then
    local wait=0
    echo "  [$prefix] проверяю, что nginx принимает конфиг..."
    while [ "$wait" -lt 40 ]; do
      if docker exec nginx-proxy nginx -t 2>/dev/null; then
        echo "  [$prefix] конфиг принят (прошло ${wait}c)"
        break
      fi
      sleep 2
      wait=$((wait + 2))
    done
    if [ "$wait" -ge 40 ]; then
      echo "  ERROR: [$prefix] конфиг НЕ принимается после пересоздания — АВТО-ОТКАТ" >&2
      # Откат: возврат предыдущего compose
      if [ -f "/opt/docker/backups/${prefix}-conf/docker-compose.yml.prev" ]; then
        echo "  откат: возвращаю предыдущую версию compose"
        cp -f "/opt/docker/backups/${prefix}-conf/docker-compose.yml.prev" "$compose_file"
        docker compose -f "$compose_file" up -d 2>&1
      fi
      # Восстановление ручных сетей, если они были
      if [ -n "$saved_nets" ]; then
        for net in $saved_nets; do
          docker network connect "$net" nginx-proxy 2>/dev/null || true
        done
      fi
      # Повторная проверка
      sleep 5
      if docker exec nginx-proxy nginx -t 2>/dev/null; then
        echo "  откат: nginx снова принимает конфиг, ingress восстановлен"
      else
        echo "  ERROR: откат не помог — нужен ручной разбор" >&2
      fi
      echo "$stamp_old" > "$stamp2"
      HAD_ERRORS=1
      return
    fi
  fi

  # Восстановить ручные сети
  if [ -n "$saved_nets" ] && [ -n "$cont_name" ]; then
    local current_nets
    current_nets=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$cont_name" 2>/dev/null)
    for net in $saved_nets; do
      case " $current_nets " in
        *" $net "*) : ;;
        *) docker network connect "$net" "$cont_name" 2>/dev/null \
             && echo "  [$prefix] восстановлена сеть: $net" ;;
      esac
    done
  fi

  echo "$stamp_new" > "$stamp2"
  echo "  [$prefix] отпечаток обновлён"
}

# reverse-proxy
restart_stack "nginx-proxy" "$DSH_STAMP" "$RP_TARGET_HOST" ""

# dsh
restart_stack "dsh" "$DSH_STAMP" "$DSH_TARGET" "Dockerfile.dsh"

# unset agents_disabled — чтобы деплой не зависал при следующем мерже
if [ -f "$AGENTS_DISABLED_FILE" ]; then
  rm -f "$AGENTS_DISABLED_FILE" 2>/dev/null || true
fi

# dsh agents enrolment: вкл/выкл инструментария агентов
if [ -f "$DSH_DISABLED_FILE" ]; then
  # при disabled — не включаем
  :
elif docker exec dsh bash -lc 'node /home/dsh/dsh/dist/dsh.js flag --action=get --flag=AGENTS_ENABLED' 2>/dev/null | grep -q 'true'; then
  echo "  dsh: AGENTS_ENABLED уже установлен"
else
  docker exec dsh bash -lc 'node /home/dsh/dsh/dist/dsh.js flag --action=set --flag=AGENTS_ENABLED --value=1' 2>/dev/null \
    && echo "  dsh: AGENTS_ENABLED = 1 (установлен)" || echo "  dsh: AGENTS_ENABLED не доступен (флаг не на месте?)"
fi

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

echo "===  nginx: reload config  ==="
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