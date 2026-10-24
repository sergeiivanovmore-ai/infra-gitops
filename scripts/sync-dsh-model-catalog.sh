#!/bin/bash
# Приводит каталог моделей DSH (settings.yaml) к agents/dsh/model-catalog.yaml.
# Добавляет отсутствующие id, удаляет помеченные retired; копия до правки, откат из копии.
# Перезапускает dsh ТОЛЬКО если файл изменился. Временный файл - рядом, не в /tmp.
# Использование: bash sync-dsh-model-catalog.sh [/путь/к/settings.yaml]
set -u
REPO=/opt/infra-gitops
CAT="$REPO/agents/dsh/model-catalog.yaml"
CFG="${1:-/opt/docker/dsh/data/settings.yaml}"
BACKUP=/root/dsh-model-backups
RESTART=dsh
TS=$(date +%Y%m%d-%H%M%S)
OWNER=${DSH_CONFIG_OWNER:-10001:10001}
fix_owner() { chown "$OWNER" "$1" 2>/dev/null && chmod 600 "$1" 2>/dev/null || say "  warn: cannot set owner/perms on $1"; }
say() { echo "[dsh-catalog] $*"; }

[ -f "$CAT" ] || { say "нет $CAT - пропуск"; exit 0; }
[ -f "$CFG" ] || { say "нет $CFG - пропуск"; exit 0; }
mkdir -p "$BACKUP"
BAK="$BACKUP/settings.yaml.$TS"
cp -a "$CFG" "$BAK" || { say "не сделать копию - пропуск"; exit 1; }

TMP=$(mktemp "$CFG.XXXXXX") || { say "cannot create temp file - skip"; rm -f "$BAK"; exit 1; }
trap 'rm -f "$TMP"' EXIT
cat "$CFG" > "$TMP" || { say "не создать временный файл - пропуск"; rm -f "$BAK"; exit 1; }

python3 - "$CAT" "$TMP" <<'PY'
import sys
cat, tmp = sys.argv[1], sys.argv[2]
want, ret, sec = [], [], None
for l in open(cat, encoding='utf-8'):
    s = l.strip()
    if s.startswith('retired:'):
        sec = 'r'
    elif s.startswith('models:'):
        sec = 'm'
    elif s.startswith('- id:'):
        (ret if sec == 'r' else want).append(s[5:].strip())
lines = open(tmp, encoding='utf-8').read().split('\n')
i0 = i1 = None
for i, l in enumerate(lines):
    if l.rstrip() == '      models:':
        i0, i1 = i, i + 1
        while i1 < len(lines) and (not lines[i1].strip() or lines[i1][0].isspace()):
            i1 += 1
        break
if i0 is None:
    print('  каталог моделей: секция models не найдена - пропуск')
    sys.exit(10)
have = [l.split('id:', 1)[1].strip() for l in lines[i0+1:i1] if l.strip().startswith('- id:')]
add = [w for w in want if w not in have]
drop = [r for r in ret if r in have]
if not add and not drop:
    print('  каталог моделей: изменений не требуется')
    sys.exit(10)
keep = [l for l in lines[i0+1:i1] if not (l.lstrip().startswith('- id:') and l.split('id:', 1)[1].strip() in ret)]
body = [l for l in keep if l.strip()]
for a in add:
    body.append('        - id: ' + a)
open(tmp, 'w', encoding='utf-8').write('\n'.join(lines[:i0+1] + body + lines[i1:]))
for a in add:
    print('  + ' + a)
for d in drop:
    print('  - ' + d)
sys.exit(0)
PY
rc=$?
if [ "$rc" -eq 10 ]; then
  rm -f "$TMP" "$BAK"
  say "готово"
  exit 0
fi
if [ "$rc" -ne 0 ] || cmp -s "$TMP" "$CFG"; then
  say "ОШИБКА правки - восстанавливаю из копии"
  cp -a "$BAK" "$CFG"; fix_owner "$CFG"
  rm -f "$TMP"
  exit 1
fi
say "diff:"
diff "$CFG" "$TMP" | sed 's/^/    /'
chmod --reference="$BAK" "$TMP" 2>/dev/null || true
mv -f "$TMP" "$CFG" || { say "ОШИБКА установки - восстанавливаю"; cp -a "$BAK" "$CFG"; fix_owner "$CFG"; exit 1; }
fix_owner "$CFG"
say "записано: $CFG (копия: $BAK)"
st=$(docker inspect "$RESTART" --format '{{.State.Status}}' 2>/dev/null || echo none)
if [ "$st" = "running" ]; then
  if docker restart "$RESTART" >/dev/null 2>&1; then say "перезапущен: $RESTART"; else say "НЕ удалось перезапустить $RESTART"; fi
else
  say "$RESTART не запущен (статус: $st) - перезапуск не требуется"
fi
say "готово"
