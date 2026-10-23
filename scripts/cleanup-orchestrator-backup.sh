#!/bin/bash
# Удаление устаревших бэкапов данных оркестратора (data.backup-*).
#
# Контекст 2026-10-23: диск 86%, из 8.2 ГБ каталога hermes-orchestrator 4.0 ГБ
# занимал ручной бэкап data.backup-2026-10-14 — копия того же дерева, что уже
# лежит в data/. Контейнер монтирует только data/ (проверено docker inspect),
# бэкап не используется ничем.
#
# Деструктивный скрипт: без --yes только проверяет и печатает план.
# Удаление: bash scripts/cleanup-orchestrator-backup.sh --yes
#
# Проверки (не прошла — каталог пропускается):
#   1) живой data/ существует и не пуст;
#   2) ни один compose-файл не упоминает data.backup;
#   3) каталог не участвует ни в одном монтировании (/proc/*/mountinfo);
#   4) у каждого элемента верхнего уровня бэкапа есть пара в data/;
#   5) все installs/<id> из бэкапа присутствуют в data/installs/.
set -u

ORCH="/opt/docker/hermes-orchestrator"
DATA="$ORCH/data"
APPLY=0
[ "${1:-}" = "--yes" ] && APPLY=1

if [ ! -d "$DATA" ]; then
  echo "НЕТ живого каталога $DATA — прерываю" >&2
  exit 1
fi
if [ ! -d "$ORCH" ]; then
  echo "НЕТ каталога $ORCH — прерываю" >&2
  exit 1
fi

found=0
for target in "$ORCH"/data.backup-*; do
  [ -d "$target" ] || continue
  found=1
  base=$(basename "$target")
  echo "=== $base ($(du -sh "$target" 2>/dev/null | cut -f1))"
  fail=""

  if [ -z "$(ls -A "$DATA" 2>/dev/null)" ]; then
    fail="живой data/ пуст"
  fi

  if [ -z "$fail" ] && grep -rqs -- "data.backup" /opt/docker/*/docker-compose.yml /opt/docker/*/*.yml 2>/dev/null; then
    fail="каталог упоминается в compose-файле"
  fi

  if [ -z "$fail" ] && grep -rsq -- "$target" /proc/*/mountinfo 2>/dev/null; then
    fail="каталог участвует в монтировании"
  fi

  if [ -z "$fail" ]; then
    for e in "$target"/*; do
      [ -e "$e" ] || continue
      n=$(basename "$e")
      if [ ! -e "$DATA/$n" ]; then
        fail="в бэкапе есть элемент без пары в data/: $n"
        break
      fi
    done
  fi

  if [ -z "$fail" ] && [ -d "$target/installs" ]; then
    for i in "$target"/installs/*; do
      [ -d "$i" ] || continue
      n=$(basename "$i")
      if [ ! -d "$DATA/installs/$n" ]; then
        fail="установка $n есть только в бэкапе"
        break
      fi
    done
  fi

  if [ -n "$fail" ]; then
    echo "  ПРОПУСК: $fail"
    continue
  fi

  if [ "$APPLY" = "1" ]; then
    size=$(du -sh "$target" 2>/dev/null | cut -f1)
    rm -rf -- "$target"
    echo "  УДАЛЁН, освобождено: $size"
  else
    echo "  проверки пройдены; чтобы удалить: bash $0 --yes"
  fi
done

if [ "$found" = "0" ]; then
  echo "каталогов data.backup-* нет — чистить нечего"
fi

echo "--- диск после ---"
df -h / | tail -1