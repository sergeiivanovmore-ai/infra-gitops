#!/bin/bash
# Чистка кешей и мусора Docker на хосте. Ничего не удаляет без --yes.
#
# ЗАЧЕМ: диск занят на 86%. Разбор показал, что /var/lib/docker почти пуст (137 МБ),
# а 29 ГБ лежат в /var/lib/containerd — Docker 29 держит образы в containerd-хранилище.
# Поэтому чистка идёт штатными командами docker, а не удалением каталогов руками.
#
# ПРИНЦИПЫ: список целей только явный (никакого `docker system prune` наугад);
# каждая цель проверяется до удаления; по умолчанию режим плана.
set -u

MIN_USED_PCT=75

case "${1:-}" in
  "")     MODE=plan ;;
  --yes)  MODE=apply ;;
  *)      echo "использование: $0 [--yes]"; exit 2 ;;
esac

[ "$(id -u)" = "0" ] || { echo "нужен root"; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "docker не найден"; exit 2; }

say() { echo "$*"; }

pct_used() { df -P / | awk 'NR==2 {gsub("%","",$5); print $5}'; }
disk_line() { df -h / | awk 'NR==2 {print $3" занято, "$4" свободно ("$5")"}'; }
human_gb() { awk -v b="$1" 'BEGIN{printf "%.2f", b/1073741824}'; }

PCT=$(pct_used)
say "== чистка Docker-кешей и мусора =="
say "режим: $MODE"
say "диск до: $(disk_line)"

if [ "$PCT" -lt "$MIN_USED_PCT" ]; then
  say "занято ${PCT}% — ниже порога ${MIN_USED_PCT}%, чистка не требуется"
  exit 0
fi

# --- 1. образы, которые не держит ни один контейнер: только явный список -----
UNUSED_IMAGES="nousresearch/hermes-agent:latest hermes-architectural-mcp:local"
say ""
say "-- 1. неиспользуемые образы (явный список) --"
for img in $UNUSED_IMAGES; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    say "  $img — уже отсутствует"
    continue
  fi
  n=$(docker ps -a --filter "ancestor=$img" --format '{{.ID}}' | wc -l)
  size=$(docker image inspect "$img" --format '{{.Size}}')
  if [ "$n" -gt 0 ]; then
    say "  $img — ПРОПУСК: образ держат контейнеры ($n)"
    continue
  fi
  say "  $img — $(human_gb "$size") ГБ, контейнеров нет — к удалению"
  if [ "$MODE" = apply ]; then
    if docker image rm "$img" >/dev/null 2>&1; then say "    удалён"; else say "    НЕ удалось удалить"; fi
  fi
done

# --- 2. висячие образы (<none>): безопасно, только dangling ------------------
say ""
say "-- 2. висячие образы --"
dang=$(docker images -f dangling=true -q | wc -l)
say "  найдено: $dang"
if [ "$MODE" = apply ] && [ "$dang" -gt 0 ]; then
  docker image prune -f >/dev/null 2>&1 && say "  удалены"
fi

# --- 3. кеш сборки ----------------------------------------------------------
say ""
say "-- 3. кеш сборки --"
say "  $(docker system df --format '{{.Type}}: {{.Size}}' 2>/dev/null | grep -i 'build' || echo 'нет данных')"
if [ "$MODE" = apply ]; then
  docker builder prune -af >/dev/null 2>&1 && say "  кеш очищен"
fi

# --- 4. json-логи контейнеров, которых больше нет ---------------------------
say ""
say "-- 4. json-логи мёртвых контейнеров (больше 50 МБ) --"
live=$(docker ps -a --format '{{.ID}}')
found=0
for logf in /var/lib/docker/containers/*/*-json.log; do
  [ -f "$logf" ] || continue
  sz=$(stat -c %s "$logf")
  [ "$sz" -gt 52428800 ] || continue
  cid=$(basename "$(dirname "$logf")")
  short=${cid:0:12}
  if printf '%s\n' "$live" | grep -q "^${short}"; then
    say "  $short — $((sz/1048576)) МБ — ПРОПУСК: контейнер существует (логи стоит ограничить в compose)"
    continue
  fi
  found=$((found+1))
  say "  $short — $((sz/1048576)) МБ — контейнера нет, лог под удаление"
  [ "$MODE" = apply ] && rm -f "$logf"
done
[ "$found" -eq 0 ] && say "  ничего не найдено"

# --- 5. журнал systemd ------------------------------------------------------
say ""
say "-- 5. журнал systemd --"
say "  $(journalctl --disk-usage 2>/dev/null || echo 'недоступен')"
if [ "$MODE" = apply ]; then
  journalctl --vacuum-size=200M >/dev/null 2>&1 && say "  сжато до 200 МБ"
fi

# --- 6. кеш apt -------------------------------------------------------------
say ""
say "-- 6. кеш apt --"
say "  $(du -sh /var/cache/apt 2>/dev/null | cut -f1)"
if [ "$MODE" = apply ]; then
  apt-get clean >/dev/null 2>&1 && say "  очищен"
fi

# --- 7. бэкап оркестратора: отдельный скрипт со своими проверками -----------
say ""
say "-- 7. бэкап оркестратора (отдельный скрипт) --"
BACKUP_CLEANER=/opt/infra-gitops/scripts/cleanup-orchestrator-backup.sh
if [ -f "$BACKUP_CLEANER" ]; then
  if [ "$MODE" = apply ]; then
    bash "$BACKUP_CLEANER" --yes || say "  завершился с ошибкой — см. вывод выше"
  else
    bash "$BACKUP_CLEANER" || say "  завершился с ошибкой — см. вывод выше"
  fi
else
  say "  $BACKUP_CLEANER не найден — пропуск"
fi

say ""
say "диск после: $(disk_line)"
if [ "$MODE" = plan ]; then
  say "это план: ничего не удалялось. применение — только с --yes, а --yes приходит"
  say "исключительно из подтверждения человеком (файл approvals/ в main)."
fi
exit 0
