#!/bin/bash
# Драйвер пакетного рендера: ОДИН процесс Blender на предмет.
#
# Зачем так: в одном процессе память монотонно растёт от повторного импорта
# FBX (на Лорэне 1082 меша × 890 actions) и прогон умирает с EXIT=137 (OOM)
# где-то на 38-м предмете из 42. Отдельный процесс чистый по определению.
#
# Возобновляемость: готовые предметы пропускаются по наличию обоих файлов,
# поэтому после падения достаточно перезапустить скрипт.
#
#   ROOT=/path/to/model ./run_batch_render.sh
set -u

ROOT=${ROOT:?укажи ROOT=/path/to/model}
N=${N:-42}
BLENDER=${BLENDER:-/tmp/blender-4.2.3-linux-x64/blender}
BATCH=${BATCH:-/tmp/vil/lorena_batch.py}     # или scripts/batch_export_isolated.py
SAMPLES=${SAMPLES:-64}
RES=${RES:-1024}

LOG=$ROOT/logs/batch.log
PROG=$ROOT/logs/progress.txt
mkdir -p "$ROOT/logs" "$ROOT/parts" "$ROOT/renders"
: > "$PROG"

export LOR_FBX=$ROOT/input/$(basename "$(ls "$ROOT"/input/*.fbx "$ROOT"/input/*.FBX 2>/dev/null | head -1)")
export LOR_OUT=$ROOT
export LOR_SAMPLES=$SAMPLES
export LOR_RES=$RES

echo "FBX=$LOR_FBX" > "$LOG"
echo "предметов: $N, samples=$SAMPLES, res=$RES" >> "$LOG"

for n in $(seq 1 "$N"); do
    # пропуск готовых (для возобновления после OOM)
    if [ -s "$ROOT/parts/$n.fbx" ] && [ -s "$ROOT/renders/${n}_iso.png" ]; then
        echo "PROGRESS $n/$N SKIP (уже готов)" >> "$PROG"
        continue
    fi

    echo "=== START $n $(date '+%H:%M:%S') ===" >> "$LOG"
    LOR_ONLY=$n timeout 900 "$BLENDER" --background --factory-startup \
        --python "$BATCH" >> "$LOG" 2>&1
    rc=$?
    echo "=== END $n exit=$rc $(date '+%H:%M:%S') ===" >> "$LOG"
    echo "PROGRESS $n/$N exit=$rc $(date '+%H:%M:%S')" >> "$PROG"

    if [ "$rc" = "137" ]; then
        echo "!! OOM на предмете $n — прогон возобновляем, перезапустите скрипт" >> "$LOG"
    fi
done

echo "BATCH_LOOP_COMPLETE $(date '+%H:%M:%S')" >> "$LOG"

# --- проверка (структурная; НЕ заменяет глаза) ---
missing=0
for n in $(seq 1 "$N"); do
    [ -s "$ROOT/parts/$n.fbx" ] || { echo "НЕТ FBX: $n"; missing=1; }
    [ -s "$ROOT/renders/${n}_iso.png" ] || { echo "НЕТ PNG: $n"; missing=1; }
done
[ "$missing" = "0" ] && echo "структурно: все $N предметов на месте" || echo "ЕСТЬ ПРОБЕЛЫ"
echo "!! теперь открой 4-5 рендеров через vision_analyze — empty=0 этого не доказывает"
echo "DRIVER_COMPLETE"