#!/bin/bash
# Read-only отчёт о состоянии VPS + оценка тревог. Ничего не меняет.
# Отчёт печатается в stdout и кладётся в bind hermes-sysadmin:
#   /opt/docker/hermes-sysadmin/data/logs/diag-last.md
# откуда агент читает его локально — у контейнера агента нет выхода в сеть.
# Код возврата: 1 — есть тревоги (workflow краснеет -> GitHub шлёт письмо),
# 0 — тревог нет. Отчёт публикуется в любом случае.
set -u

REPORT_LOCAL="/opt/docker/hermes-sysadmin/data/logs/diag-last.md"
DEPLOY_LOG="/opt/docker/hermes-sysadmin/data/logs/deploy-last.log"
OUT=$(mktemp /tmp/diag-infra.XXXXXX.md)
ALERTS=""

say() { printf '%s\n' "$*" >> "$OUT"; }
add_alert() { ALERTS="${ALERTS}- $1"$'\n'; }

say "# Инфра-отчёт"
say "Снят: $(date -Iseconds)"
say "Хост: $(hostname) | ядро: $(uname -r)"

say ""
say "## Контейнеры: статус, рестарты, здоровье"
for c in $(docker ps -a --format '{{.Names}}' | sort); do
  st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)
  rc=$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null)
  hl=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$c" 2>/dev/null)
  sd=$(docker inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null | cut -c1-19)
  say "$c | $st | restarts=$rc | health=$hl | $sd"
  if [ "$c" != "hermes-gateway" ] && [ "$st" != "running" ]; then
    add_alert "контейнер $c: статус $st"
  fi
  if [ "${rc:-0}" != "0" ]; then
    add_alert "контейнер $c: рестартов $rc"
  fi
  if [ "$hl" = "unhealthy" ]; then
    add_alert "контейнер $c: health=unhealthy"
  fi
done

say ""
say "## Сети контейнеров (ручные подключения теряются при пересоздании)"
for c in $(docker ps --format '{{.Names}}' | sort); do
  nets=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c" 2>/dev/null)
  say "$c: $nets"
  if [ "$c" = "nginx-proxy" ]; then
    case " $nets " in *" hermes-net "*) ;; *) add_alert "nginx-proxy: потеряна сеть hermes-net — апстримы не разрешатся" ;; esac
    case " $nets " in *" vpn-net "*) ;; *) add_alert "nginx-proxy: потеряна сеть vpn-net" ;; esac
  fi
done

say ""
say "## Ресурсы"
df -h / | tail -1 >> "$OUT"
dp=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "${dp:-0}" -ge 88 ]; then
  add_alert "диск /: занято ${dp}%"
fi
awk '/MemTotal|MemAvailable/{print}' /proc/meminfo >> "$OUT"
ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
if [ "${ma:-0}" -lt 307200 ]; then
  add_alert "память: свободно $(( ma / 1024 )) МБ"
fi
say "loadavg: $(cat /proc/loadavg)"

say ""
say "## nginx: проверка конфига"
ngx=$(docker exec nginx-proxy nginx -t 2>&1 | tail -2)
say "$ngx"
if ! printf '%s' "$ngx" | grep -q "test is successful"; then
  add_alert "nginx -t: конфигурация не проходит проверку"
fi

say ""
say "## Домены"
for u in jt-design.ru stg.jt-design.ru sysadmin.jt-design.ru analists.jt-design.ru orchestrator.jt-design.ru; do
  code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "https://$u/" 2>/dev/null || echo ERR)
  say "$u=$code"
  case "$code" in
    2??|3??) ;;
    *) add_alert "домен $u отвечает $code" ;;
  esac
done

say ""
say "## Сертификаты: срок действия"
for d in /etc/letsencrypt/live/*/; do
  [ -f "$d/cert.pem" ] || continue
  name=$(basename "$d")
  end=$(openssl x509 -enddate -noout -in "$d/cert.pem" 2>/dev/null | cut -d= -f2)
  [ -n "$end" ] || continue
  days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  say "$name | $end | дней: $days"
  if [ "$days" -lt 14 ]; then
    add_alert "сертификат $name: истекает через $days дн."
  fi
done

say ""
say "## Почта: очередь Postfix"
mq=$(docker exec mail-relay postqueue -p 2>/dev/null | tail -3)
say "${mq:-postqueue недоступен}"
if printf '%s' "$mq" | grep -q "Queue ID"; then
  add_alert "Postfix: в очереди есть письма"
fi

say ""
say "## Последний прогон деплоя (хвост)"
if [ -f "$DEPLOY_LOG" ]; then
  tail -4 "$DEPLOY_LOG" >> "$OUT"
  if tail -30 "$DEPLOY_LOG" | grep -q "ERROR"; then
    add_alert "последний прогон деплоя содержит ERROR"
  fi
else
  say "лог не найден: $DEPLOY_LOG"
fi

say ""
say "## Диск: крупнейшие каталоги /opt/docker (глубина 2)"
timeout 60 du -xh --max-depth=2 /opt/docker/*/ 2>/dev/null | sort -h | tail -12 >> "$OUT"

say ""
say "## Диск: крупнейшие файлы больше 100 МБ"
timeout 60 find /opt/docker -xdev -type f -size +100M -printf '%k KB\t%p\n' 2>/dev/null | sort -n | tail -12 >> "$OUT"

say ""
say "## ТРЕВОГИ"
if [ -n "$ALERTS" ]; then
  printf '%s' "$ALERTS" >> "$OUT"
else
  say "нет"
fi

mkdir -p "$(dirname "$REPORT_LOCAL")" 2>/dev/null
cp -f "$OUT" "$REPORT_LOCAL" 2>/dev/null
chmod 644 "$REPORT_LOCAL" 2>/dev/null
cat "$OUT"
rm -f "$OUT"

if [ -n "$ALERTS" ]; then
  echo
  echo "уровень тревог: $(printf '%s' "$ALERTS" | grep -c '^- ')"
  exit 1
fi
exit 0