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
CODE=$(curl -s -o /dev/null -w '%{http_code}' -m "$(th http_timeout_sec 10)" -H "Host: $SITE" http://127.0.0.1/ 2>/dev/null || echo 000)
if [ "$CODE" != "200" ]; then
  add p1 ingress "вход через nginx-proxy не отвечает 200" "http: 200 -> $CODE" "curl -I -H 'Host: $SITE' http://127.0.0.1/"
fi
printf 'restarts=%s\n' "${RC_NOW:-0}" > "$PREV" 2>/dev/null || true

# --- 4. диск ---
CHECKS=$((CHECKS+1))
DPATH=$(th disk_path /)
PCT=$(df -P "$DPATH" | awk 'NR==2{gsub("%","",$5);print $5+0}')
INODE=$(df -Pi "$DPATH" | awk 'NR==2{gsub("%","",$5);print $5+0}')
FREE=$(df -Ph "$DPATH" | awk 'NR==2{print $4}')
WARN=$(th disk_warn_percent 70); CRIT=$(th disk_used_percent 80); INOC=$(th inode_used_percent 85)
if [ "${PCT:-0}" -ge "$CRIT" ]; then
  add p1 disk "диск заполнен выше порога" "занято: ${PCT}% (порог ${CRIT}%), свободно ${FREE}" "df -h $DPATH; du -x -h -d1 / | sort -h | tail"
elif [ "${PCT:-0}" -ge "$WARN" ]; then
  add p2 disk "диск приближается к порогу" "занято: ${PCT}% (порог ${WARN}%), свободно ${FREE}" "df -h $DPATH"
fi
if [ "${INODE:-0}" -ge "$INOC" ]; then
  add p2 disk "много использованных inode" "inode: ${INODE}% (порог ${INOC}%)" "df -i $DPATH"
fi

# --- 7. агенты и модели ---
CHECKS=$((CHECKS+1))
WIN=$(th agent_log_error_window_min 120)
PAT='API failed after 3 retries|Final error|Key limit exceeded|free launch period'
LIST=$(curl -sS -m 20 "$(th provider_models_url https://openrouter.ai/api/v1/models)" 2>/dev/null || true)
[ -n "$LIST" ] || add log model "список моделей провайдера недоступен с хоста" "проверка существования моделей пропущена" "curl -sS https://openrouter.ai/api/v1/models"
for F in "$REPO"/agents/*/models.yaml; do
  [ -f "$F" ] || continue
  A=$(basename "$(dirname "$F")")
  KIND=$(grep -m1 '^kind:' "$F" | sed 's/^[^:]*:[[:space:]]*//')
  CFG=$(grep -m1 '^config:' "$F" | sed 's/^[^:]*:[[:space:]]*//')
  CONT=$(grep -m1 '^restart:' "$F" | sed 's/^[^:]*:[[:space:]]*//')
  if [ "$KIND" = "dsh" ]; then
    WANT=$(grep -m1 '^dsh_model:' "$F" | sed 's/^[^:]*:[[:space:]]*//')
  else
    WANT=$(grep -m1 '^model_default:' "$F" | sed 's/^[^:]*:[[:space:]]*//')
  fi
  [ -n "$WANT" ] || continue
  if [ -f "$CFG" ] && ! grep -qF "$WANT" "$CFG"; then
    add p2 drift "$A: модель в конфиге не совпадает с GitOps" "ожидается: $WANT" "grep -n model $CFG | head"
  fi
  if [ -n "$LIST" ] && ! printf '%s' "$LIST" | grep -qF "\"id\":\"$WANT\""; then
    add p1 model "$A: модель недоступна у провайдера" "$WANT отсутствует в списке моделей" "curl -s https://openrouter.ai/api/v1/models | grep -o $WANT | head -1"
  fi
  if [ -n "$CONT" ]; then
    ERRS=$(docker logs --since "${WIN}m" --tail 400 "$CONT" 2>&1 | grep -cE "$PAT" || true)
    if [ "${ERRS:-0}" -gt 0 ]; then
      LAST=$(docker logs --since "${WIN}m" --tail 400 "$CONT" 2>&1 | grep -E "$PAT" | tail -1 | cut -c1-180)
      add p1 model "$A: ошибки обращения к модели за ${WIN} мин" "ошибок: $ERRS" "$LAST"
    fi
  fi
done

# --- сборка отчёта ---
python3 - "$FIND" "$MD" "$JS" "$TS" "$NODE" "$CHECKS" <<'PY'
import json, sys
src, md_path, js_path, ts, node, checks = sys.argv[1:7]
rows = []
for line in open(src, encoding='utf-8'):
    line = line.rstrip('\n')
    if not line:
        continue
    parts = (line.split('|') + [''] * 5)[:5]
    rows.append(dict(severity=parts[0], id=parts[1], summary=parts[2], metric=parts[3], detail=parts[4]))
order = {'p1': 0, 'ci': 1, 'p2': 2, 'log': 3}
rows.sort(key=lambda r: order.get(r['severity'], 9))
bad = [r for r in rows if r['severity'] in ('p1', 'ci')]
overall = 'P1' if bad else ('P2' if any(r['severity'] == 'p2' for r in rows) else 'OK')
labels = {'p1': 'P1 - будит', 'ci': 'CI - красный прогон', 'p2': 'P2 - в ленту', 'log': 'в лог'}
out = ['# Отчёт о здоровье VPS', '', '- время: ' + ts, '- узел: ' + node,
       '- итог: ' + overall, '- проверок: ' + checks + ', отклонений: ' + str(len(rows)), '']
for sev in ('p1', 'ci', 'p2', 'log'):
    group = [r for r in rows if r['severity'] == sev]
    if not group:
        continue
    out.append('## ' + labels[sev])
    out.append('')
    for r in group:
        out.append('- ' + r['id'] + ' — ' + r['summary'] + ' — ' + r['metric'])
        if r['detail']:
            out.append('  - шаги: ' + r['detail'])
    out.append('')
text = '\n'.join(out)
open(md_path, 'w', encoding='utf-8').write(text + '\n')
json.dump({'generated': ts, 'node': node, 'overall': overall, 'checks': int(checks),
           'findings': rows}, open(js_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
sys.stdout.write(text + '\n')
sys.exit(1 if bad else 0)
PY
RC=$?
rm -f "$FIND"
if [ "$QUIET" = "1" ]; then exit "$RC"; fi
exit "$RC"