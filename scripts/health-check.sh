#!/bin/bash
# health-check.sh — проверки здоровья VPS. ТОЛЬКО ЧТЕНИЕ: ничего не меняет,
# не перезапускает и не чинит. Пороги лежат рядом: health/thresholds.yaml.
#
# Пишет два файла в канал «хост -> агент» (/opt/docker/hermes-sysadmin/data/logs):
#   health-last.md    — отчёт для человека и для лога деплоя
#   health-state.json — машинное состояние, его читает сторож в контейнере
#
# Код возврата: 0 — в норме; 1 — есть отклонения класса P1 или CI.
# Вызов последним шагом в хвосте деплоя делает красный прогон независимым каналом.
#
# Опции:
#   --set КЛЮЧ=ЗНАЧЕНИЕ  переопределить порог (можно несколько раз), для проверки
#   --install-cron        поставить расписание /etc/cron.d/infra-health (каждые 5 мин)
#   --quiet               не дублировать отчёт в stdout
set -u

REPO=/opt/infra-gitops
TH="$REPO/health/thresholds.yaml"
OUT_DIR=/opt/docker/hermes-sysadmin/data/logs
MD="$OUT_DIR/health-last.md"
JS="$OUT_DIR/health-state.json"
PREV="$OUT_DIR/.health-prev"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NODE=$(hostname)
SELF="$REPO/scripts/health-check.sh"
FIND=$(mktemp)
OVERRIDES=""
QUIET=0
INSTALL_CRON=0
CHECKS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --set) OVERRIDES="$OVERRIDES
${2:-}"; shift 2 ;;
    --install-cron) INSTALL_CRON=1; shift ;;
    --quiet) QUIET=1; shift ;;
    *) echo "неизвестная опция: $1" >&2; exit 2 ;;
  esac
done

th() { # th КЛЮЧ ЗНАЧЕНИЕ_ПО_УМОЛЧАНИЮ
  local k="$1" d="$2" v o
  o=$(printf '%s\n' "$OVERRIDES" | grep -m1 "^$k=" | cut -d= -f2-)
  [ -n "$o" ] && { echo "$o"; return; }
  v=""
  [ -f "$TH" ] && v=$(grep -m1 "^$k:" "$TH" | sed "s/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^[\"']//; s/[\"']$//")
  echo "${v:-$d}"
}
add() { printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$FIND"; }
say() { echo "[health] $*"; }

if [ "$INSTALL_CRON" = "1" ]; then
  CRON=/etc/cron.d/infra-health
  TMP=$(mktemp)
  {
    echo 'SHELL=/bin/bash'
    echo 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    echo "*/5 * * * * root bash $SELF --quiet >/dev/null 2>&1"
  } > "$TMP"
  if cmp -s "$TMP" "$CRON" 2>/dev/null; then
    say "расписание без изменений: $CRON"
  else
    install -m 0644 "$TMP" "$CRON" && say "расписание обновлено: $CRON (каждые 5 минут)"
  fi
  rm -f "$TMP"
  exit 0
fi

mkdir -p "$OUT_DIR" 2>/dev/null || true

# --- 1. ingress: nginx-proxy жив, не перезапускался, отвечает 200 ---
CHECKS=$((CHECKS+1))
C=nginx-proxy
ST=$(docker inspect "$C" --format '{{.State.Status}}' 2>/dev/null || echo missing)
RC_NOW=$(docker inspect "$C" --format '{{.RestartCount}}' 2>/dev/null || echo 0)
RC_PREV=$(grep -m1 '^restarts=' "$PREV" 2>/dev/null | cut -d= -f2 || true)
if [ "$ST" != "running" ]; then
  add p1 ingress "nginx-proxy не работает" "статус: running -> $ST" "docker ps -a | grep nginx-proxy"
fi
if [ -n "${RC_PREV:-}" ] && [ "${RC_NOW:-0}" -gt "${RC_PREV:-0}" ] 2>/dev/null; then
  add p1 ingress "nginx-proxy перезапускался" "RestartCount: $RC_PREV -> $RC_NOW" "docker logs --tail 50 nginx-proxy"
fi
SITE=$(th site_host jt-design.ru)
TIMEOUT=$(th http_timeout_sec 10)
# Смотрим глазами посетителя: https с нужным хостом, через loopback, чтобы не зависеть от DNS.
# Раньше шёл http, переадресация 301 на https давала ложный P1.
CODE=$(curl -sk -o /dev/null -w '%{http_code}' -m "$TIMEOUT" --resolve "$SITE:443:127.0.0.1" "https://$SITE/" 2>/dev/null || echo 000)
if [ "$CODE" != "200" ]; then
  add p1 ingress "вход через nginx-proxy не отвечает 200" "https: 200 -> $CODE" "curl -skI --resolve $SITE:443:127.0.0.1 https://$SITE/"
fi
# Переадресация http -> https штатна; необычные коды — предупреждение, не тревога.
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m "$TIMEOUT" -H "Host: $SITE" http://127.0.0.1/ 2>/dev/null || echo 000)
case "$HTTP_CODE" in
  200|301|302) : ;;
  *) add p2 ingress "http-вход ведёт себя необычно" "http: 200/301 -> $HTTP_CODE" "curl -I -H 'Host: $SITE' http://127.0.0.1/" ;;
esac
printf 'restarts=%s\n' "${RC_NOW:-0}" > "$PREV" 2>/dev/null || true