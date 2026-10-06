"""
Blender: РАЗДЕЛЕНИЕ модели с выбором конкретных частей.

Ключевое отличие от analyze_and_split.py: можно задать --select 1,3,5 —
скрипт создаст ТОЛЬКО эти части, каждая в изолированной свежей сцене
(clear_scene -> импорт ТОЛЬКО нужной группы), чтобы избежать
кросс-контаминации объектов.

Запуск:
  blender --background --python split_selected.py -- \
      --input /path/model.fbx \
      --out /path/to/models \
      --parts 4 \
      --select 1,3,5 \
      [--axis auto] [--mapping element_1:0,element_2:1]

Печатает: SPLIT_JSON {...}
"""

import json
import os
import sys

import bpy

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import split_core  # noqa: E402


def parse_args(argv):
    a = {
        "input": "", "out": "", "parts": "auto", "axis": "auto",
        "select": "", "mapping": "", "min_gap_ratio": 0.0,
    }
    i = 0
    while i < len(argv):
        k = argv[i]
        if k == "--input":
            a["input"] = argv[i + 1]; i += 2
        elif k == "--out":
            a["out"] = argv[i + 1]; i += 2
        elif k == "--parts":
            a["parts"] = argv[i + 1]; i += 2
        elif k == "--axis":
            a["axis"] = argv[i + 1]; i += 2
        elif k == "--select":
            a["select"] = argv[i + 1]; i += 2
        elif k == "--mapping":
            a["mapping"] = argv[i + 1]; i += 2
        elif k == "--min-gap-ratio":
            a["min_gap_ratio"] = float(argv[i + 1]); i += 2
        else:
            i += 1
    return a


def clear_scene():
    """Полная очистка сцены — обязательна перед каждой загрузкой."""
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras,
                 bpy.data.lights, bpy.data.images):
        for blk in list(coll):
            if blk.users == 0:
                try:
                    coll.remove(blk)
                except Exception:
                    pass


def parse_mapping(spec):
    """'a:0,b:1,2' -> {'a': [0], 'b': [1, 2]}"""
    out = {}
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            name, cids = part.split(":", 1)
        else:
            name, cids = part, part
        try:
            out[name.strip()] = [int(x) for x in cids.split("+") if x.strip() != ""]
        except ValueError:
            continue
    return out


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parse_args(argv)

    if not os.path.exists(args["input"]):
        print("SPLIT_JSON " + json.dumps({"error": "Файл не найден: %s" % args["input"]},
                                         ensure_ascii=False))
        return
    os.makedirs(args["out"], exist_ok=True)

    # ---- Шаг 1: анализ исходной модели (одна сцена) ----
    clear_scene()
    bpy.ops.import_scene.fbx(filepath=args["input"])
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not objs:
        print("SPLIT_JSON " + json.dumps({"error": "В модели нет меш-объектов"},
                                         ensure_ascii=False))
        return

    info = split_core.analyze(objs, args["parts"], args["axis"], args["min_gap_ratio"])
    mapping = parse_mapping(args["mapping"]) if args["mapping"] else None
    groups = split_core.resolve_mapping(info["clusters"], mapping)

    # ---- Шаг 2: фильтр по --select ----
    available = sorted(groups.keys(), key=lambda k: int(k))
    if args["select"].strip():
        wanted = [s.strip() for s in args["select"].split(",") if s.strip()]
        missing = [w for w in wanted if w not in groups]
        groups = {k: v for k, v in groups.items() if k in wanted}
    else:
        wanted = available

    if not groups:
        print("SPLIT_JSON " + json.dumps(
            {"error": "После фильтрации не осталось ни одной части",
             "available": available, "requested": wanted}, ensure_ascii=False))
        return

    # ---- Шаг 3: изолированный экспорт каждой группы ----
    manifest = {}
    exported = []
    for name in sorted(groups.keys(), key=lambda k: int(k)):
        obj_names = groups[name]

        # Изолированная сцена: только объекты этой группы
        clear_scene()
        bpy.ops.import_scene.fbx(filepath=args["input"])
        scene_objs = {o.name: o for o in bpy.context.scene.objects}
        picked = []
        for nm in obj_names:
            o = scene_objs.get(nm)
            if o and o.type == "MESH":
                picked.append(o)
        if not picked:
            manifest[name] = {"objects": len(obj_names), "exported": False,
                              "reason": "объекты не найдены при повторном импорте"}
            continue

        bpy.ops.object.select_all(action="DESELECT")
        for o in picked:
            o.select_set(True)
        bpy.context.view_layer.objects.active = picked[0]

        path = os.path.join(args["out"], "%s.fbx" % name)
        bpy.ops.export_scene.fbx(filepath=path, use_selection=True,
                                bake_anim=False, bake_anim_use_all_actions=False,
                                bake_anim_use_nla_strips=False,
                                bake_anim_force_startend_keying=False)
        exported.append(name)
        manifest[name] = {"objects": len(picked), "exported": True,
                          "path": path, "size": os.path.getsize(path)}

    # Метаданные для рендера и загрузки
    with open(os.path.join(args["out"], "groups.json"), "w") as f:
        json.dump(groups, f, ensure_ascii=False, indent=2)
    with open(os.path.join(args["out"], "split_manifest.json"), "w") as f:
        json.dump({"source": args["input"], "axis": info["axis"],
                   "parts_requested": args["parts"],
                   "parts_mode": info["parts_mode"],
                   "planned_parts": info["planned_parts"],
                   "selected": sorted(groups.keys(), key=lambda k: int(k)),
                   "manifest": manifest}, f, ensure_ascii=False, indent=2)

    print("SPLIT_JSON " + json.dumps(
        {"source": args["input"], "axis": info["axis"],
         "parts_requested": args["parts"], "parts_mode": info["parts_mode"],
         "objects": info["objects"], "planned_parts": info["planned_parts"],
         "gaps_usable": info["gaps_usable"],
         "available": available, "requested": wanted,
         "exported": exported, "out_dir": args["out"],
         "missing_selection": missing if args["select"].strip() else []},
        ensure_ascii=False))


main()