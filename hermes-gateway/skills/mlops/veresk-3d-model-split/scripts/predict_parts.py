"""
Blender: ПРОГНОЗ разделения (без экспорта).

Загружает FBX, определяет главную ось, находит естественные зазоры и
сообщает, СКОЛЬКО моделей получится и что в каждой из них.

Запуск:
  blender --background --python predict_parts.py -- \
      --input /path/model.fbx --parts 4 [--axis auto]

Печатает в stdout строку:
  PREDICT_JSON { ... }
"""

import json
import os
import sys

import bpy

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import split_core  # noqa: E402


def parse_args(argv):
    a = {"input": "", "parts": "auto", "axis": "auto", "min_gap_ratio": 0.0}
    i = 0
    while i < len(argv):
        k = argv[i]
        if k == "--input":
            a["input"] = argv[i + 1]
            i += 2
        elif k == "--parts":
            a["parts"] = argv[i + 1]
            i += 2
        elif k == "--axis":
            a["axis"] = argv[i + 1]
            i += 2
        elif k == "--min-gap-ratio":
            a["min_gap_ratio"] = float(argv[i + 1])
            i += 2
        else:
            i += 1
    return a


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parse_args(argv)

    if not os.path.exists(args["input"]):
        print("PREDICT_JSON " + json.dumps({"error": "Файл не найден: %s" % args["input"]},
                                          ensure_ascii=False))
        return

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    bpy.ops.import_scene.fbx(filepath=args["input"])

    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not objs:
        print("PREDICT_JSON " + json.dumps({"error": "В модели нет меш-объектов"},
                                          ensure_ascii=False))
        return

    info = split_core.analyze(objs, args["parts"], args["axis"], args["min_gap_ratio"])
    groups = split_core.resolve_mapping(info["clusters"], None)

    parts_mode = info["parts_mode"]
    planned = info["planned_parts"]

    warnings = []
    if info["not_enough_gaps"]:
        warnings.append(
            "Запрошено %s частей, но естественных зазоров хватает только на %d — "
            "части будут неравномерными." % (args["parts"], planned)
        )
    if planned > 20:
        warnings.append(
            "Автосегментация нашла %d зазоров → %d моделей. Это много: "
            "рендер каждой займёт значительное время. Можно отфильтровать мелкие "
            "зазоры через --min-gap-ratio 0.01 (получится %d частей) или задать "
            "фиксированное число частей."
            % (info["gaps_usable"], planned, info["planned_parts_robust"])
        )
    if info["gaps_robust"] < info["gaps_usable"]:
        warnings.append(
            "Из %d зазоров только %d крупных (>1%% от длины модели) — "
            "остальные могут быть щелями между мелкими деталями."
            % (info["gaps_usable"], info["gaps_robust"])
        )

    out = {
        "file": os.path.basename(args["input"]),
        "path": args["input"],
        "parts_requested": args["parts"],
        "parts_mode": parts_mode,
        "planned_parts": planned,
        "planned_parts_robust": info["planned_parts_robust"],
        "axis": info["axis"],
        "detected_axis": info["detected_axis"],
        "spans": {k: round(v, 4) for k, v in info["spans"].items()},
        "total_span": round(info["total_span"], 4),
        "objects": info["objects"],
        "gaps_total": info["gaps_total"],
        "gaps_usable": info["gaps_usable"],
        "gaps_robust": info["gaps_robust"],
        "gaps_top": [
            {"gap": round(g["gap"], 4), "gap_pct": round(100.0 * g["gap"] / info["total_span"], 2),
             "left": round(g["left"], 4), "right": round(g["right"], 4)}
            for g in info["gaps"][:12]
        ],
        "split_positions": [round(s, 4) for s in info["splits"]],
        "not_enough_gaps": info["not_enough_gaps"],
        "warnings": warnings,
        "parts": [
            {
                "number": int(k),
                "objects": len(v),
                "range": [
                    round(next(c["min"] for c in info["clusters"] if str(c["idx"] + 1) == k), 4),
                    round(next(c["max"] for c in info["clusters"] if str(c["idx"] + 1) == k), 4),
                ],
                "names_sample": v[:8],
            }
            for k, v in sorted(groups.items(), key=lambda kv: int(kv[0]))
        ],
    }
    print("PREDICT_JSON " + json.dumps(out, ensure_ascii=False))


main()