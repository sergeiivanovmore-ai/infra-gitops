#!/bin/bash
# Дополнительные проверки здоровья: домены и сайт, сертификаты, почтовая очередь.
# Вызывается из health-check.sh. Пишет находки в файл-аргумент в формате
# severity|id|кратко|метрика|подробно. stdout — ТОЛЬКО новое число проверок.
# Пороги — health/thresholds.yaml; разовые переопределения приходят в HEALTH_SETS.
set -u

FIND="$1"
CHECKS="${2:-0}"
REPO=/opt/infra-gitops
TH="$REPO/health/thresholds.yaml"

th() {
  local k="$1" d="$2" v o
  o=$(printf '%s\n' "${HEALTH_SETS:-}" | grep -m1 "^$k=" | cut -d= -f2-)
  [ -n "$o" ] && { echo "$o"; return; }
  v=""
  [ -f "$TH" ] && v=$(grep -m1 "^$k:" "$TH" | sed "s/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*$//")
  echo "${v:-$d}"
}
add() { printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$FIND"; }

DOMAINS=$(th domains jt-design.ru)
TIMEOUT=$(th http_timeout_sec 10)
SITE=$(th site_host jt-design.ru)
SITE_DIR=$(th site_dir /opt/docker/jt-design-site)

# --- домены и сайт ---
CHECKS=$((CHECKS+1))
for D in $DOMAINS; do
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' -m "$TIMEOUT" --resolve "$D:443:127.0.0.1" "https://$D/" 2>/dev/null || echo 000)
  [ "$CODE" != "200" ] && add p2 domain "$D: вход не отвечает 200" "https: 200 -> $CODE" "curl -skI --resolve $D:443:127.0.0.1 https://$D/"
done
if [ -f "$SITE_DIR/index.html" ] && [ -n "$SITE" ]; then
  SERVED=$(curl -sk -m "$TIMEOUT" --resolve "$SITE:443:127.0.0.1" "https://$SITE/" 2>/dev/null | wc -c)
  LOCAL=$(wc -c < "$SITE_DIR/index.html")
  [ "${SERVED:-0}" != "$LOCAL" ] && add p2 site "сайт отдаёт не то, что развёрнуто" "размер: $LOCAL -> $SERVED" "curl -sk https://$SITE/ | wc -c; wc -c $SITE_DIR/index.html"
fi

# --- сертификаты: класс CI (в лог и красный прогон, без пробуждения) ---
CHECKS=$((CHECKS+1))
CDAYS=$(th cert_days 30)
for D in $DOMAINS; do
  END=$(echo | timeout 15 openssl s_client -connect 127.0.0.1:443 -servername "$D" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -z "$END" ]; then
    add ci cert "$D: не удалось прочитать сертификат" "openssl не вернул дату" "echo | openssl s_client -connect 127.0.0.1:443 -servername $D | openssl x509 -noout -dates"
    continue
  fi
  LEFT=$(python3 -c "import datetime;print((datetime.datetime.strptime('$END','%b %d %H:%M:%S %Y %Z')-datetime.datetime.utcnow()).days)" 2>/dev/null || echo "")
  if [ -n "$LEFT" ] && [ "$LEFT" -lt "$CDAYS" ]; then
    add ci cert "$D: сертификат истекает" "осталось: $LEFT дн (порог $CDAYS)" "echo | openssl s_client -connect 127.0.0.1:443 -servername $D | openssl x509 -noout -dates"
  fi
done

# --- почтовая очередь ---
CHECKS=$((CHECKS+1))
MCT=$(th mail_container mail-relay)
MQW=$(th mail_queue_warn 20)
MQC=$(th mail_queue_crit 200)
if docker inspect "$MCT" >/dev/null 2>&1; then
  PQ="/tmp/pq.$$"
  rm -rf "$PQ"
  mkdir -p "$PQ"
  if docker cp "$MCT:/var/spool/postfix/deferred" "$PQ/deferred" >/dev/null 2>&1; then
    QN=$(find "$PQ/deferred" -type f 2>/dev/null | wc -l)
    if [ "${QN:-0}" -ge "$MQC" ]; then
      add p1 mail "письма стоят в очереди" "в deferred: $QN (порог $MQC)" "docker cp $MCT:/var/spool/postfix/deferred /tmp/pq && ls /tmp/pq/deferred"
    elif [ "${QN:-0}" -ge "$MQW" ]; then
      add p2 mail "растёт почтовая очередь" "в deferred: $QN (порог $MQW)" "docker cp $MCT:/var/spool/postfix/deferred /tmp/pq && ls /tmp/pq/deferred"
    fi
  fi
  rm -rf "$PQ"
fi

echo "$CHECKS"