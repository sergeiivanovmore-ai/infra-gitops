#!/bin/bash
# модуль проверок: пишет находки в $FIND, в stdout — новое число проверок

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
CODE=$(curl -sk -o /dev/null -w '%{http_code}' -m "$TIMEOUT" --resolve "$SITE:443:127.0.0.1" "https://$SITE/" 2>/dev/null || echo 000)
if [ "$CODE" != "200" ]; then
  add p1 ingress "вход через nginx-proxy не отвечает 200" "https: 200 -> $CODE" "curl -skI --resolve $SITE:443:127.0.0.1 https://$SITE/"
fi
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m "$TIMEOUT" -H "Host: $SITE" http://127.0.0.1/ 2>/dev/null || echo 000)
case "$HTTP_CODE" in
  200|301|302) : ;;
  *) add p2 ingress "http-вход ведёт себя необычно" "http: 200/301 -> $HTTP_CODE" "curl -I -H 'Host: $SITE' http://127.0.0.1/" ;;
esac
printf 'restarts=%s\n' "${RC_NOW:-0}" > "$PREV" 2>/dev/null || true
echo "$CHECKS"