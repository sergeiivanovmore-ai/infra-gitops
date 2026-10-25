#!/bin/bash
# Батч разбиения+рендера: ОДИН процесс Blender на предмет.
#
# Зачем по одному процессу, а не один батч на всё:
#   - память растёт при повторном импорте FBX -> OOM (EXIT=137) на длинных прогонах
#   - падение одного предмета не убивает весь прогон
#   - можно перезапустить с любого номера
#
# Аргументы передаются через переменные окружения, а не через "--":
# разделитель приводит к тому, что blender читает флаги как имена файлов.
#
# Использование:
#   FBX=... CLUSTERS=... OUT=... N=42 SAMPLES=64 RES=1024 \
#   BLENDER=... BATCH_SCRIPT=... ./run_batch_isolated.sh

set -u

FBX="${FBX:?нужен путь к исходному FBX}"
CLUSTERS="${CLUSTERS:?нужен JSON с кластерами (members)}"
OUT="${OUT:?нуть каталога результата}"
BATCH_SCRIPT="${BATCH_SCRIPT:?нуть скрипт батча на python}"
BLENDER="${BLENDER:-/tmp/blender-4.2.3-linux-x64/blender}"
N="${N:-42}"
SAMPLES="${SAMPLES:-64}"
RES="${RES:-1024}"

export LOR_FBX="$FBX"
export LOR_CLUSTERS="$CLUSTERS"
export LOR_OUT="$OUT"
export LOR_SAMPLES="$SAMPLES"
export LOR_RES="$RES"

LOG="$OUT/logs/batch.log"
PROG="$OUT/logs/progress.txt"
mkdir -p "$OUT/logs" "$OUT/parts" "$OUT/renders"
: > "$LOG"
: > "$PROG"

for n in $(seq 1 "$N"); do
    echo "=== START $n $(date '+%H:%M:%S') ===" >> "$LOG"
    LOR_ONLY=$n timeout 900 "$BLENDER" \
        --background --factory-startup \
        --python "$BATCH_SCRIPT" >> "$LOG" 2>&1
    rc=$?
    echo "=== END $n exit=$rc $(date '+%H:%M:%S') ===" >> "$LOG"
    echo "PROGRESS $n/$N exit=$rc $(date '+%H:%M:%S')" >> "$PROG"
done

echo "ALL_DONE $(date '+%H:%M:%S')" >> "$LOG"
echo "BATCH_COMPLETE $N/$N"