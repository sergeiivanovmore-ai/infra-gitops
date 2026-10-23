#!/bin/bash
# Read-only отчёт о состоянии VPS. Ничего не меняет, пишет только в stdout.
# Запускается по SSH из .github/workflows/diagnose.yml; результат публикуется
# в ветку reports/diag, откуда его читает агент (логи Actions отдают 403).
set -u

echo "# Инфра-отчёт"
echo "Снят: $(date -Iseconds)"
echo "Хост: $(hostname) | ядро: $(uname -r)"

echo
echo "## Контейнеры: статус, рестарты, здоровье"
for c in $(docker ps -a --format '{{.Names}}' | sort); do
  printf '%s | %s | restarts=%s | health=%s | %s\n' \
    "$c" \
    "$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" \
    "$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null)" \
    "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$c" 2>/dev/null)" \
    "$(docker inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null | cut -c1-19)"
done

echo
echo "## Сети контейнеров (ручные подключения теряются при пересоздании)"
for c in $(docker ps --format '{{.Names}}' | sort); do
  printf '%s: %s\n' "$c" "$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c" 2>/dev/null)"
done

echo
echo "## Ресурсы"
df -h / | tail -1
awk '/MemTotal|MemAvailable/{print}' /proc/meminfo
printf 'loadavg: %s\n' "$(cat /proc/loadavg)"

echo
echo "## nginx: проверка конфига"
docker exec nginx-proxy nginx -t 2>&1 | tail -2

echo
echo "## Домены"
for u in jt-design.ru stg.jt-design.ru sysadmin.jt-design.ru analists.jt-design.ru orchestrator.jt-design.ru; do
  printf '%s=%s\n' "$u" "$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "https://$u/" 2>/dev/null || echo ERR)"
done

echo
echo "## Сертификаты: срок действия"
for d in /etc/letsencrypt/live/*/; do
  [ -f "$d/cert.pem" ] || continue
  printf '%s | %s\n' "$(basename "$d")" "$(openssl x509 -enddate -noout -in "$d/cert.pem" 2>/dev/null | cut -d= -f2)"
done

echo
echo "## Почта: очередь Postfix"
docker exec mail-relay postqueue -p 2>/dev/null | tail -3 || echo "postqueue недоступен"

echo
echo "## Последний прогон деплоя (хвост)"
tail -4 /opt/docker/hermes-sysadmin/data/logs/deploy-last.log 2>/dev/null || echo "лог не найден"

echo
echo "## /opt: крупнейшие каталоги"
du -sh /opt/docker/* 2>/dev/null | sort -h | tail -6
