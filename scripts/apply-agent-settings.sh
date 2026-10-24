#!/bin/bash
# Наложение оверрайдов настроек из agents/<агент>/settings/*.yaml на конфиги агентов.
#
# Запускается из хвоста деплоя (scripts/ops-publish-entry.sh), поэтому
# действует только то, что лежит в main репозитория.
#
# СВОЙСТВА, ЗАШИТЫЕ В КОД (не в обещания):
#   - меняет ТОЛЬКО блоки групп из agents/*/settings/<группа>.yaml;
#   - всегда делает копию конфига в /root/agent-settings-backups/ перед правкой;
#   - при любой ошибке восстанавливает файл из копии;
#   - если значения уже такие — файл не меняется и агент НЕ перезапускается;
#   - не запускает остановленные контейнеры (gateway закрыт guard'ом);
#   - большие конфиги не пересобираются парсером YAML: правится нужный блок,
#     остальное содержимое и комментарии остаются байт в байт.
set -u

REPO=${REPO:-/opt/infra-gitops}
AGENTS_DIR="$REPO/agents"
BACKUP_DIR=/root/agent-settings-backups
TS=$(date -u +%Y%m%d-%H%M%S)

LOG() { echo "[settings] $*"; }

normalize() {
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]*$//'
}

extract_block() {
  local group="$1" cfg="$2"
  awk -v g="$group" '
    $0 ~ "^" g ":" { in_block=1; print; next }
    in_block && /^[A-Za-z_]/ { exit }
    in_block { print }
  ' "$cfg"
}

mkdir -p "$BACKUP_DIR"
[ -d "$AGENTS_DIR" ] || { LOG "нет каталога $AGENTS_DIR -- применять нечего"; exit 0; }

errors=0

for f in "$AGENTS_DIR"/*/models.yaml; do
  [ -f "$f" ] || continue
  A=$(basename "$(dirname "$f")")
  CFG=$(grep -m1 '^config:' "$f" | sed 's/^config:[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//')
  CONT=$(grep -m1 '^restart:' "$f" | sed 's/^restart:[[:space:]]*//')
  LOG "--- $A ---"
  if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then
    LOG "  конфиг не найден (${CFG:-не задан}) -- пропуск"
    continue
  fi

  SETTINGS_DIR="$REPO/agents/$A/settings"
  [ -d "$SETTINGS_DIR" ] || { LOG "  нет каталога настроек $SETTINGS_DIR -- пропуск"; continue; }

  for setting_file in "$SETTINGS_DIR"/*.yaml; do
    [ -f "$setting_file" ] || continue
    G=$(basename "$setting_file" .yaml)
    LOG "  --- $A / $G ---"

    BAK="$BACKUP_DIR/$A-config.yaml.$TS"
    cp -a "$CFG" "$BAK" || { LOG "  не сделать копию -- пропуск"; errors=$((errors+1)); continue; }

    override_norm=$(normalize < "$setting_file")
    current_norm=$(extract_block "$G" "$CFG" | normalize)

    if [ "$override_norm" = "$current_norm" ]; then
      LOG "    изменений не требуется"
      rm -f "$BAK"
      continue
    fi

    TMP="/tmp/settings.$$"
    cp -a "$CFG" "$TMP"

    python3 - "$G" "$setting_file" "$TMP" <<'PY'
import re, sys
group_name, override_path, cfg_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(override_path, encoding='utf-8') as f:
    override_content = f.read()
lines = open(cfg_path, encoding='utf-8').read().split('\n')
start = None
end = None
for i, l in enumerate(lines):
    if re.match(r'^' + re.escape(group_name) + r':\s*(#.*)?$', l):
        start = i
        for j in range(i + 1, len(lines)):
            s = lines[j]
            if s.strip() and not s[0].isspace() and not s.lstrip().startswith('#'):
                end = j
                break
        if end is None:
            end = len(lines)
        break
override_lines = override_content.rstrip('\n').split('\n')
if start is None:
    if lines and lines[-1].strip():
        lines.append('')
    lines.extend(override_lines)
else:
    lines[start:end] = override_lines
open(cfg_path, 'w', encoding='utf-8').write('\n'.join(lines))
PY
    rc=$?
    if [ "$rc" -ne 0 ]; then
      LOG "    ОШИБКА правки -- восстанавливаю из копии"
      cp -a "$BAK" "$CFG"
      errors=$((errors+1))
      rm -f "$BAK"
      continue
    fi

    ok=1
    if grep -q $'\t' "$TMP"; then ok=0; fi
    top_before=$(grep -c '^[A-Za-z_][A-Za-z0_9]*:' "$BAK" 2>/dev/null || echo 0)
    top_after=$(grep -c '^[A-Za-z_][A-Za-z0_9]*:' "$TMP" 2>/dev/null || echo 0)
    if [ "$top_before" != "$top_after" ]; then ok=0; fi
    if ! grep -q "^$G:" "$TMP"; then ok=0; fi
    if [ "$ok" -eq 0 ]; then
      LOG "    Структурная проверка провалена -- откат из копии"
      cp -a "$BAK" "$CFG"
      errors=$((errors+1))
      rm -f "$BAK"
      continue
    fi

    mv -f "$TMP" "$CFG" || { LOG "    ОШИБКА установки -- восстанавливаю из копии"; cp -a "$BAK" "$CFG"; errors=$((errors+1)); rm -f "$BAK"; continue; }

    LOG "    diff:"
    diff -u "$BAK" "$CFG" | sed 's/^/      /' || true
    LOG "    изменено: $A / $G"

    ST=$(docker inspect "$CONT" --format '{{.State.Running}}' 2>/dev/null || echo false)
    if [ "$ST" = "true" ]; then
      if docker restart "$CONT" >/dev/null 2>&1; then
        LOG "    перезапущен: $CONT"
      else
        LOG "    НЕ удалось перезапустить $CONT"
      fi
    else
      LOG "    контейнер не запущен -- перезапуск не требуется"
    fi

  done
done

if [ "$errors" -gt 0 ]; then
  LOG "есть ошибки у $errors агентов"
  exit 1
fi
LOG "готово"
exit 0