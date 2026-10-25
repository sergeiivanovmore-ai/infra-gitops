"""
Склейка нескольких PNG в один (вертикальный стек) — внутри Blender (numpy).

Нужен, когда модель сильно вытянута: один широкий кадр даёт крошечные
модули, а Telegram пережимает широкие картинки. Решается разрезом модели
на 2-4 части и склейкой в одну картинку — линейная детализация растёт
во столько раз, сколько частей.

Запуск:
  blender --background --python stack_images.py -- \
      --inputs a.png b.png --output stacked.png [--gap 12] [--bg 1.0]

Печатает: STACK_JSON {...}
"""

import json
import os
import sys

import bpy
import numpy as np


def load_rgb(path):
    img = bpy.data.images.load(path)
    w, h = img.size
    buf = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(buf)
    arr = buf.reshape(h, w, 4)          # Blender хранит снизу вверх
    arr = np.flipud(arr)                # переворачиваем в обычный порядок
    bpy.data.images.remove(img)
    return arr


def crop_to_content(arr):
    """Обрезает прозрачные поля. Фон рендера прозрачный (film_transparent)."""
    a = arr[:, :, 3]
    if float(a.max()) <= 0.001:          # всё прозрачное — нечего резать
        return arr
    rows = np.where(a.max(axis=1) > 0.002)[0]
    cols = np.where(a.max(axis=0) > 0.002)[0]
    if len(rows) == 0 or len(cols) == 0:
        return arr
    pad = 4
    r0 = max(0, rows[0] - pad); r1 = min(arr.shape[0], rows[-1] + pad + 1)
    c0 = max(0, cols[0] - pad); c1 = min(arr.shape[1], cols[-1] + pad + 1)
    return arr[r0:r1, c0:c1]


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    inputs, output, gap, bg = [], "", 12, 1.0
    autocrop = False
    i = 0
    while i < len(argv):
        if argv[i] == "--inputs":
            inputs = argv[i + 1].split(","); i += 2
        elif argv[i] == "--output":
            output = argv[i + 1]; i += 2
        elif argv[i] == "--gap":
            gap = int(argv[i + 1]); i += 2
        elif argv[i] == "--crop":
            autocrop = argv[i + 1].lower() in ("auto", "1", "true", "yes"); i += 2
        elif argv[i] == "--bg":
            bg = float(argv[i + 1]); i += 2
        else:
            i += 1

    arrs = [load_rgb(p) for p in inputs if os.path.exists(p)]
    if not arrs:
        print("STACK_JSON " + json.dumps({"error": "нет входных картинок"},
                                         ensure_ascii=False))
        return

    if autocrop:
        arrs = [crop_to_content(a) for a in arrs]

    width = min(a.shape[1] for a in arrs)
    height = sum(a.shape[0] for a in arrs) + gap * (len(arrs) - 1)

    canvas = np.ones((height, width, 4), dtype=np.float32)
    canvas[:, :, 3] = 1.0
    # тонкие разделители, чтобы было видно где какой кусок
    y = 0
    for n, a in enumerate(arrs):
        h, w = a.shape[0], a.shape[1]
        if w >= width:
            x0 = (w - width) // 2
            crop = a[:, x0:x0 + width]
        else:
            # дополняем прозрачностью по бокам, а НЕ растягиваем первый столбец
            crop = np.zeros((h, width, 4), dtype=np.float32)
            x0 = (width - w) // 2
            crop[:, x0:x0 + w] = a
        canvas[y:y + h] = crop
        y += h
        if n < len(arrs) - 1:
            yy = y + gap // 2
            canvas[yy:yy + 1, :, 0] = 0.55
            canvas[yy:yy + 1, :, 1] = 0.75
            canvas[yy:yy + 1, :, 2] = 0.95
            y += gap

    canvas = np.flipud(canvas)                          # обратно в порядок Blender
    out = bpy.data.images.new("stacked", width=width, height=height, alpha=True)
    out.pixels.foreach_set(canvas.ravel())
    out.filepath_raw = output
    out.file_format = "PNG"
    out.save()

    print("STACK_JSON " + json.dumps({
        "output": output, "width": width, "height": height,
        "inputs": inputs, "parts": len(arrs),
        "size_kb": round(os.path.getsize(output) / 1024.0, 1),
    }, ensure_ascii=False))


main()