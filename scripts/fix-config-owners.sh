#!/bin/bash
# Принудительно выставляет владельца и права на конфиги агентов.
# Снимае�� последствия cp/mv деплоя: файл от root становится читаемым контейнеру.
# Идемпотентно, запускается из хвоста деплоя и вручную.
#
# Использование: bash fix-config-owners.sh [--dry-run]
set -u

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say() { echo "[owners] $*"; }

rc=0

# Владелец нужен тот, под которым конфиг читает контейнер.
# Формат строки: владелец|режим|путь. Пути добавлять сюда.
while IFS='|' read -r owner mode path; do
  case "${path:-}" in ""|\#*) continue ;; esac
  if [ ! -e "$path" ]; then
    say "нет $path -- пропуск"
    continue
  fi
  cur=$(stat -c '%u:%g %a' "$path" 2>/dev/null || echo '?')
  if [ "$cur" = "$owner $mode" ]; then
    say "уже верно: $path ($cur)"
    continue
  fi
  if [ "$DRY" -eq 1 ]; then
    say "план: $path $cur -> $owner $mode"
    continue
  fi
  if chown "$owner" "$path" 2>/dev/null && chmod "$mode" "$path" 2>/dev/null; then
    say "исправлено: $path $cur -> $(stat -c '%u:%g %a' "$path")"
  else
    say "ОШИБКА: не выставить $owner $mode на $path"
    rc=1
  fi
done <<'LIST'
10000:10000|600|/opt/docker/hermes-sysadmin/data/config.yaml
10001:10001|600|/opt/docker/dsh/data/settings.yaml
LIST

if [ "$DRY" -eq 1 ]; then
  say "режим плана: изменения не применены"
else
  say "готово"
fi

exit "$rc"
