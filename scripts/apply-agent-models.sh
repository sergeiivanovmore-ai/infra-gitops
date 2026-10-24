#!/bin/bash
# Применение моделей из agents/<агент>/models.yaml к конфигам агентов на хосте.
#
# Запускается из хвоста деплоя (scripts/ops-publish-entry.sh), поэтому
# действует только то, что лежит в main репозитории.
#
# СВОЙСТВА, ЗАШИТЫЕ В КОД (не в обещания):
#   - меняет ТОЛЬКО перечисленные в models.yaml ключи модели и провайдера;
#   - всегда делает копию конфига в /root/agent-model-backups/ перед правкой;
#   - при любой ошибке восстанавливает файл из копии;
#   - если значения уже такие — файл не меняется и агент НЕ перезапускается;
#   - не запускает остановленные контейнеры (gateway закрыт guard'ом);
#   - большие конфиги не пересобираются парсером YAML: правится нужная строка,
#     остальное содержимое и комментарии остаются байт в байт.
#
# Использование: bash apply-agent-models.sh [--dry-run]
set -u

REPO=/opt/infra-gitops
AGENTS_DIR="$REPO/agents"
BACKUP_ROOT=/root/agent-model-backups
TS=$(date +%Y%m%d-%H%M%S)
CONFIG_OWNER=${AGENT_CONFIG_OWNER:-10000:10000}
fix_owner() { chown "$CONFIG_OWNER" "$1" 2>/dev/null && chmod 600 "$1" 2>/dev/null || say "  warn: cannot set owner/perms on $1"; }
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say() { echo "[models] $*"; }
mkdir -p "$BACKUP_ROOT"
[ -d "$AGENTS_DIR" ] || { say "нет каталога $AGENTS_DIR — применять нечего"; exit 0; }

for f in "$AGENTS_DIR"/*/models.yaml; do
  [ -f "$f" ] || continue
  agent=$(basename "$(dirname "$f")")
  cfg=$(grep -m1 '^config:' "$f" | sed 's/^config:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')
  restart=$(grep -m1 '^restart:' "$f" | sed 's/^restart:[[:space:]]*//')
  say "--- $agent ---"
  if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then
    say "  конфиг не найден (${cfg:-не задан}) — пропуск"
    continue
  fi

  if grep -q '^kind:[[:space:]]*dsh' "$f"; then
    bash "$REPO/scripts/sync-dsh-model-catalog.sh" "$cfg" || true
  fi

  bak="$BACKUP_ROOT/$agent-config.yaml.$TS"
  cp -a "$cfg" "$bak" || { say "  не сделать копию — пропуск"; continue; }
  tmp=$(mktemp "$cfg.XXXXXX") || { say "  warn: cannot create temp file -- skip"; continue; }
  cp -a "$cfg" "$tmp" || { say "  warn: cannot seed temp file -- skip"; rm -f "$tmp"; continue; }
  trap 'rm -f "$tmp"' EXIT

  python3 - "$f" "$tmp" <<'PY'
import re, sys
spec_path, cfg_path = sys.argv[1], sys.argv[2]

def kv(line):
    k, v = line.split(':', 1)
    return k.strip(), v.split('#')[0].strip().strip('"').strip("'")

spec = {}
for line in open(spec_path, encoding='utf-8'):
    line = line.rstrip('\n')
    if not line or line.lstrip().startswith('#') or ':' not in line:
        continue
    k, v = kv(line)
    if k:
        spec[k] = v

if spec.get('kind', 'hermes') == 'dsh':
    pairs = [('agent-default-model', 'model', spec.get('dsh_model')),
             ('agent-default-model', 'provider', spec.get('dsh_provider'))]
else:
    pairs = [('model', 'default', spec.get('model_default')),
             ('model', 'provider', spec.get('model_provider')),
             ('auxiliary', 'openrouter_model', spec.get('auxiliary_openrouter_model')),
             ('auxiliary', 'free_only', spec.get('auxiliary_free_only'))]

lines = open(cfg_path, encoding='utf-8').read().split('\n')

def bounds(name):
    for i, l in enumerate(lines):
        if re.match(r'^' + re.escape(name) + r':\s*(#.*)?$', l):
            for j in range(i + 1, len(lines)):
                s = lines[j]
                if s.strip() and not s[0].isspace() and not s.lstrip().startswith('#'):
                    return i, j
            return i, len(lines)
    return None, None

def fmt(v):
    if v.lower() in ('true', 'false') or re.fullmatch(r'-?\d+(\.\d+)?', v):
        return v
    return '"' + v + '"'

changes = []
for block, key, value in pairs:
    if not value:
        continue
    start, end = bounds(block)
    if start is None:
        if lines and lines[-1].strip():
            lines.append('')
        lines.append(block + ':')
        lines.append('  ' + key + ': ' + fmt(value))
        changes.append('+ ' + block + '.' + key + ' = ' + value + ' (блок создан)')
        continue
    indent = '  '
    for j in range(start + 1, end):
        m = re.match(r'^(\s+)\S', lines[j])
        if m:
            indent = m.group(1)
            break
    pos = None
    for j in range(start + 1, end):
        if re.match(r'^\s+' + re.escape(key) + r'\s*:', lines[j]):
            pos = j
            break
    if pos is None:
        lines.insert(start + 1, indent + key + ': ' + fmt(value))
        changes.append('+ ' + block + '.' + key + ' = ' + value)
        continue
    cur = lines[pos].split(':', 1)[1].split('#')[0].strip().strip('"').strip("'")
    if cur == value:
        continue
    comment = ''
    if '#' in lines[pos]:
        comment = '  ' + lines[pos][lines[pos].index('#'):]
    lines[pos] = indent + key + ': ' + fmt(value) + comment
    changes.append('~ ' + block + '.' + key + ': ' + cur + ' -> ' + value)

if not changes:
    print('  изменений не требуется')
    sys.exit(10)
open(cfg_path, 'w', encoding='utf-8').write('\n'.join(lines))
for c in changes:
    print('  ' + c)
sys.exit(0)
PY
  rc=$?
  if [ "$rc" -eq 10 ]; then
    rm -f "$tmp"
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    say "  ERROR: edit failed -- live config untouched"
    rm -f "$tmp"
    continue
  fi
  if cmp -s "$tmp" "$cfg"; then
    say "  no changes -- no restart needed"
    rm -f "$tmp"
    continue
  fi
  echo "  diff:"
  diff "$cfg" "$tmp" | sed 's/^/    /'
  ok=1
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c "import yaml;list(yaml.safe_load_all(open('$tmp',encoding='utf-8')))" 2>/dev/null || ok=0
  fi
  if [ "$ok" -eq 0 ]; then
    say "  warn: YAML does not parse -- live config untouched"
    rm -f "$tmp"
    continue
  fi
  if [ "$DRY" -eq 1 ]; then
    say "  dry-run: diff shown above, $cfg NOT touched"
    rm -f "$tmp"
    continue
  fi
  say "  copy: $bak"
  chmod --reference="$bak" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$cfg" || { say "  warn: install failed -- rollback from backup"; cp -a "$bak" "$cfg"; fix_owner "$cfg"; continue; }
  fix_owner "$cfg"

  st=$(docker inspect "$restart" --format '{{.State.Status}}' 2>/dev/null || echo none)
  if [ "$st" = "running" ]; then
    if docker restart "$restart" >/dev/null 2>&1; then
      say "  перезапущен: $restart"
    else
      say "  НЕ удалось перезапустить $restart"
    fi
  else
    say "  $restart не запущен (статус: $st) — перезапуск не требуется, правка вступит в силу при старте"
  fi
done
say "готово"