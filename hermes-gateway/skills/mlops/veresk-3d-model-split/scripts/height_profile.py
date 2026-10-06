"""
Blender: профиль высоты мебели вдоль главной оси.

Вместо догадок по рендерам — численный профиль: для каждого интервала
длины BIN берётся максимальная высота объектов. Так сразу видно, где
стоят высокие корпуса (2.2), где низкие тумбы (0.75) и где пустоты.

Запуск:
  blender --background --python height_profile.py -- --input model.fbx [--bin 0.5]

Печатает: PROFILE_JSON {...}
"""

import json
import os
import sys

import bpy
import mathutils


def parse_args(argv):
    a = {"input": "", "bin": 0.5, "axis": "X"}
    i = 0
    while i < len(argv):
        k = argv[i]
        if k == "--input":
            a["input"] = argv[i + 1]; i += 2
        elif k == "--bin":
            a["bin"] = float(argv[i + 1]); i += 2
        elif k == "--axis":
            a["axis"] = argv[i + 1]; i += 2
        else:
            i += 1
    return a


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parse_args(argv)

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    bpy.ops.import_scene.fbx(filepath=args["input"])
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]

    idx = {"X": 0, "Y": 1, "Z": 2}.get(args["axis"], 0)
    zi = 2
    items = []
    for o in objs:
        lo = mathutils.Vector((float("inf"),) * 3)
        hi = mathutils.Vector((-float("inf"),) * 3)
        for c in o.bound_box:
            w = o.matrix_world @ mathutils.Vector(c)
            for i in range(3):
                lo[i] = min(lo[i], w[i])
                hi[i] = max(hi[i], w[i])
        items.append({
            "name": o.name,
            "a": lo[idx], "b": hi[idx],
            "h": hi[zi] - lo[zi],
            "depth": hi[1] - lo[1],
            "center": (lo[idx] + hi[idx]) / 2.0,
        })

    if not items:
        print("PROFILE_JSON " + json.dumps({"error": "нет мешей"}, ensure_ascii=False))
        return

    lo = min(i["a"] for i in items)
    hi = max(i["b"] for i in items)
    step = args["bin"] or 0.5

    bins = []
    x = lo
    while x < hi:
        x2 = x + step
        inside = [i for i in items if i["b"] >= x and i["a"] <= x2]
        if inside:
            bins.append({
                "from": round(x, 3),
                "to": round(x2, 3),
                "max_h": round(max(i["h"] for i in inside), 3),
                "max_depth": round(max(i["depth"] for i in inside), 3),
                "count": len(inside),
                "wide": round(max(i["b"] - i["a"] for i in inside), 3),
            })
        x = x2

    # где начинаются/заканчиваются высокие корпуса (h > 1.5)
    tall = [b for b in bins if b["max_h"] > 1.5]
    runs = []
    for b in tall:
        if runs and abs(runs[-1][1] - b["from"]) < step * 1.6:
            runs[-1][1] = b["to"]
        else:
            runs.append([b["from"], b["to"]])
    runs = [[round(a, 2), round(b, 2)] for a, b in runs if b - a > 0.4]

    print("PROFILE_JSON " + json.dumps({
        "file": os.path.basename(args["input"]),
        "axis": args["axis"],
        "span": [round(lo, 3), round(hi, 3)],
        "bin": step,
        "bins": bins,
        "tall_runs": runs,
        "tall_summary": [{"x": r, "width": round(r[1] - r[0], 2)} for r in runs],
    }, ensure_ascii=False))


main()