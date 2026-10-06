"""
Blender: пространственный анализ модели «как мебель».

Ищет ОСНОВНОЙ кластер объектов (игнорируя выбросы, раздувающие bbox),
определяет габариты именно мебели, находит естественные стыки модулей
и печатает подробный отчёт.

Запуск:
  blender --background --python analyze_spatial.py -- --input model.fbx [--cover 0.95]

Печатает: ANALYSIS_JSON {...}
"""

import json
import math
import os
import sys

import bpy
import mathutils

AXES = ("X", "Y", "Z")


def parse_args(argv):
    a = {"input": "", "cover": 0.95}
    i = 0
    while i < len(argv):
        if argv[i] == "--input":
            a["input"] = argv[i + 1]; i += 2
        elif argv[i] == "--cover":
            a["cover"] = float(argv[i + 1]); i += 2
        else:
            i += 1
    return a


def obj_box(o):
    lo = mathutils.Vector((float("inf"),) * 3)
    hi = mathutils.Vector((-float("inf"),) * 3)
    for c in o.bound_box:
        w = o.matrix_world @ mathutils.Vector(c)
        for i in range(3):
            if w[i] < lo[i]:
                lo[i] = w[i]
            if w[i] > hi[i]:
                hi[i] = w[i]
    return lo, hi


def pct_range(vals, cover):
    """Диапазон, покрывающий `cover` долю значений (устойчиво к выбросам)."""
    s = sorted(vals)
    if not s:
        return s[0], s[-1] if s else (0, 0)
    k = (1.0 - cover) / 2.0
    return s[int(k * (len(s) - 1))], s[int((1 - k) * (len(s) - 1))]


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parse_args(argv)

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    bpy.ops.import_scene.fbx(filepath=args["input"])
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not objs:
        print("ANALYSIS_JSON " + json.dumps({"error": "нет мешей"}, ensure_ascii=False))
        return

    info = []
    for o in objs:
        lo, hi = obj_box(o)
        info.append({
            "name": o.name,
            "lo": [lo.x, lo.y, lo.z],
            "hi": [hi.x, hi.y, hi.z],
            "cx": (lo.x + hi.x) / 2, "cy": (lo.y + hi.y) / 2, "cz": (lo.z + hi.z) / 2,
            "w": hi.x - lo.x, "h": hi.y - lo.y, "d": hi.z - lo.z,
        })

    full_lo = [min(i["lo"][k] for i in info) for k in range(3)]
    full_hi = [max(i["hi"][k] for i in info) for k in range(3)]
    full_span = [full_hi[k] - full_lo[k] for k in range(3)]

    # --- устойчивый bbox: по покрытию центров ---
    cx_r = pct_range([i["cx"] for i in info], args["cover"])
    cy_r = pct_range([i["cy"] for i in info], args["cover"])
    cz_r = pct_range([i["cz"] for i in info], args["cover"])
    robust_span = {
        "X": round(cx_r[1] - cx_r[0], 4), "Y": round(cy_r[1] - cy_r[0], 4),
        "Z": round(cz_r[1] - cz_r[0], 4),
    }

    # --- выбросы: объекты вне устойчивого диапазона по любой оси с запасом ---
    main_band = []
    outliers = []
    for i in info:
        inside = (cx_r[0] - 0.02 * full_span[0] <= i["cx"] <= cx_r[1] + 0.02 * full_span[0]
                  and cy_r[0] - 0.02 * full_span[1] <= i["cy"] <= cy_r[1] + 0.02 * full_span[1]
                  and cz_r[0] - 0.02 * full_span[2] <= i["cz"] <= cz_r[1] + 0.02 * full_span[2])
        (main_band if inside else outliers).append(i)

    # --- главная ось по устойчивым габаритам основной массы ---
    axis = max(robust_span, key=robust_span.get)
    axis_idx = AXES.index(axis)

    # --- стыки модулей: интервалы между центрами вдоль главной оси ---
    band_sorted = sorted(main_band, key=lambda i: i[("cx", "cy", "cz")[axis_idx]])
    key = "cx" if axis == "X" else ("cy" if axis == "Y" else "cz")
    centers = [b[key] for b in band_sorted]

    gaps = []
    for i in range(len(band_sorted) - 1):
        a, b = band_sorted[i], band_sorted[i + 1]
        left = a["hi"][axis_idx]
        right = b["lo"][axis_idx]
        g = right - left
        if g > 0:
            gaps.append({
                "gap": round(g, 4),
                "pct": round(100.0 * g / robust_span[axis], 2),
                "left": round(left, 4), "right": round(right, 4),
                "between": [a["name"], b["name"]],
            })
    gaps.sort(key=lambda x: x["gap"], reverse=True)

    out = {
        "file": os.path.basename(args["input"]),
        "objects_total": len(info),
        "objects_main": len(main_band),
        "objects_outliers": len(outliers),
        "outlier_names": [o["name"] for o in outliers[:25]],
        "full_bbox": {
            "min": [round(v, 4) for v in full_lo],
            "max": [round(v, 4) for v in full_hi],
            "spans": {AXES[k]: round(full_span[k], 4) for k in range(3)},
        },
        "robust_span": robust_span,
        "main_axis": axis,
        "robust_center": {
            "X": round((cx_r[0] + cx_r[1]) / 2, 4),
            "Y": round((cy_r[0] + cy_r[1]) / 2, 4),
            "Z": round((cz_r[0] + cz_r[1]) / 2, 4),
        },
        "gaps_count": len(gaps),
        "gaps_top": gaps[:20],
    }
    print("ANALYSIS_JSON " + json.dumps(out, ensure_ascii=False))


main()