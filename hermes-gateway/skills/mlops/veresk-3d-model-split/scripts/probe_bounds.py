"""Probe: границы объектов и кластеры по зазорам -> JSON.

Запуск:
  blender --background --python probe_bounds.py -- \
      --input model.fbx --out all_modules.json [--x0 13.0 --x1 22.5] [--gap-tol 0.05]

Печатает PROBE_JSON {...}.

Зачем до первого рендера: координаты берутся из данных, а не "по картинке".
Результат сразу годится для merge_nested и для items_index.json.
"""
import bpy, json, sys
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
A = {}
i = 0
while i < len(argv):
    if argv[i].startswith("--"):
        A[argv[i][2:]] = argv[i + 1] if i + 1 < len(argv) else ""
        i += 2
    else:
        i += 1

FBX = A["input"]; OUT = A["out"]
X0 = float(A.get("x0", -1e9)); X1 = float(A.get("x1", 1e9))
AXIS = int(A.get("axis", 0))
GAP = float(A.get("gap-tol", 0.05))

bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()
for coll in (bpy.data.meshes, bpy.data.materials):
    for b in list(coll):
        if b.users == 0:
            coll.remove(b)

bpy.ops.import_scene.fbx(filepath=FBX)
meshes = [o for o in bpy.context.scene.objects
          if o.type == 'MESH' and len(o.data.vertices)]

rows = []
for o in meshes:
    cs = [o.matrix_world @ Vector(c) for c in o.bound_box]
    co = [c[AXIS] for c in cs]
    cmin, cmax = min(co), max(co)
    zs = [c[2] for c in cs]
    if cmax < X0 or cmin > X1:
        continue
    rows.append({"name": o.name,
                 "min": round(cmin, 4), "max": round(cmax, 4),
                 "ctr": round((cmin + cmax) / 2.0, 4),
                 "len": round(cmax - cmin, 4),
                 "zmin": round(min(zs), 3), "zmax": round(max(zs), 3),
                 "h": round(max(zs) - min(zs), 3),
                 "verts": len(o.data.vertices)})

# сортируем по координате: bpy.types.Object в кортежах сравнивать нельзя
rows.sort(key=lambda r: (r["min"], r["max"]))

groups, cur = [], []
for i, r in enumerate(rows):
    cur.append(r)
    if i + 1 < len(rows) and rows[i + 1]["min"] - r["max"] > GAP:
        groups.append(cur)
        cur = [r]
if cur:
    groups.append(cur)

out_groups = [{"x_min": min(x["min"] for x in g), "x_max": max(x["max"] for x in g),
               "n_obj": len(g), "zmin": min(x["zmin"] for x in g),
               "zmax": max(x["zmax"] for x in g),
               "members": [x["name"] for x in g]} for g in groups]

res = {"mesh_count": len(meshes), "in_zone": len(rows), "axis": AXIS,
       "gap_tol": GAP, "objects": rows, "groups": out_groups}
with open(OUT, "w") as f:
    json.dump(res, f, ensure_ascii=False, indent=1)

print("PROBE_JSON=" + json.dumps(
    {"mesh_count": len(meshes), "in_zone": len(rows),
     "groups": len(out_groups), "out": OUT}))