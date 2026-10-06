#!/usr/bin/env python3
"""Проверка ВСЕГО комплекта экспортированных FBX одним запуском Blender.

Зачем: при разделении на десятки частей проверять каждую отдельным запуском
дорого и бессмысленно. Здесь за один прогон ре-импортируются все части,
считается сумма объектов и габариты, печатается вердикт.

Что ловит:
  * дублирование геометрии (сумма объектов > ожидаемой) — признак того, что
    диапазоны частей ПЕРЕСЕКАЮТЬСЯ и объект попал в две части;
  * потерю объектов (сумма < ожидаемой);
  * пустые файлы и файлы без геометрии;
  * сорванную изоляцию сцены (объектов больше, чем ожидалось).

Использование:
    blender --background --python verify_all_parts.py -- \\
        --parts-dir /path/models --out /path/verify_report.json \\
        --expect-objects 1069
"""
import bpy, json, sys, argparse, os
from mathutils import Vector


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--parts-dir", required=True)
    p.add_argument("--out", default="/tmp/verify_report.json")
    p.add_argument("--expect-objects", type=int, default=None,
                   help="объектов в исходном FBX; None — проверку суммы пропустить")
    p.add_argument("--axis", type=int, default=0)
    p.add_argument("--quiet", action="store_true",
                   help="не печатать построчный прогресс (только итог)")
    return p.parse_args(argv)


def clear_scene():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()
    for coll in (bpy.data.meshes, bpy.data.materials):
        for b in list(coll):
            if b.users == 0:
                coll.remove(b)


def main():
    a = parse_args()
    files = sorted(f for f in os.listdir(a.parts_dir) if f.endswith(".fbx"))
    if not files:
        print("VERIFY_JSON " + json.dumps({"files": 0, "verdict": "FAIL",
                                           "detail": "нет FBX в папке"}, ensure_ascii=False))
        return 1
    print("FILES=%d" % len(files), flush=True)

    rows = []
    total = 0
    for f in files:
        clear_scene()
        bpy.ops.import_scene.fbx(filepath=os.path.join(a.parts_dir, f))
        objs = [o for o in bpy.context.scene.objects
                if o.type == 'MESH' and len(o.data.vertices)]
        n = len(objs)
        total += n
        geo = None
        if objs:
            cs = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
            lo = [min(c[i] for c in cs) for i in range(3)]
            hi = [max(c[i] for c in cs) for i in range(3)]
            geo = {"x": [round(lo[0], 3), round(hi[0], 3)],
                   "y": [round(lo[1], 3), round(hi[1], 3)],
                   "z": [round(lo[2], 3), round(hi[2], 3)]}
        rows.append({
            "file": f, "objects": n,
            "verts": sum(len(o.data.vertices) for o in objs),
            "polys": sum(len(o.data.polygons) for o in objs),
            "geo": geo,
        })
        if not a.quiet:
            print("CHK %s objects=%d" % (f, n), flush=True)

    empty = [r["file"] for r in rows if r["objects"] == 0]
    no_geo = [r["file"] for r in rows if r["geo"] is None]

    problems = []
    if empty:
        problems.append("пустые части: %s" % ", ".join(map(str, empty)))
    if no_geo:
        problems.append("части без геометрии: %s" % ", ".join(map(str, no_geo)))
    if a.expect_objects is not None:
        if total > a.expect_objects:
            problems.append("ДУБЛИРОВАНИЕ: сумма %d > ожидалось %d — диапазоны частей "
                            "пересекаются, объект попал в две части" % (total, a.expect_objects))
        elif total < a.expect_objects:
            problems.append("ПОТЕРЯ: сумма %d < ожидалось %d — часть объектов не "
                            "попала ни в одну часть" % (total, a.expect_objects))

    res = {"files": len(rows), "total_objects": total,
           "expected_objects": a.expect_objects,
           "empty": empty, "no_geometry": no_geo, "problems": problems,
           "verdict": "PASS" if not problems else "FAIL",
           "parts": rows}
    with open(a.out, "w") as fh:
        json.dump(res, fh, ensure_ascii=False, indent=1)

    print("VERIFY_JSON " + json.dumps(
        {k: v for k, v in res.items() if k != "parts"}, ensure_ascii=False), flush=True)
    print("ALL_DONE verdict=%s" % res["verdict"], flush=True)
    return 0 if res["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())