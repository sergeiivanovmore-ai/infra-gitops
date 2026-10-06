"""Структурная проверка экспортированного FBX: ре-импорт и сверка с ожиданием.

  blender --background --python verify_export_fbx.py -- \
      --fbx parts/7.fbx --expect-objects 11 --expect-x 13.618:14.918 \
      --expect-z 0.804:1.554

Печатает VERIFY_JSON {...} и VERDICT: PASS/FAIL.

Зачем: рендер показывает только то, что видно. Лишние объекты внутри файла
(сорванная изоляция сцены, неверный --select) на картинке не заметны.
"""
import bpy, json, sys

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
A = {}
i = 0
while i < len(argv):
    if argv[i].startswith("--"):
        A[argv[i][2:]] = argv[i + 1] if i + 1 < len(argv) else ""
        i += 2
    else:
        i += 1

FBX = A["fbx"]
AXIS = int(A.get("axis", 0))

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
    cs = [o.matrix_world @ __import__("mathutils").Vector(c) for c in o.bound_box]
    rows.append({"name": o.name,
                 "verts": len(o.data.vertices), "polys": len(o.data.polygons),
                 "a": [round(min(c[AXIS] for c in cs), 3),
                       round(max(c[AXIS] for c in cs), 3)],
                 "z": [round(min(c[2] for c in cs), 3),
                       round(max(c[2] for c in cs), 3)]})

allc = [o.matrix_world @ __import__("mathutils").Vector(c)
        for o in meshes for c in o.bound_box]
ax = "xyz"[AXIS]
out = {"file": FBX, "n_objects": len(meshes),
       "total_verts": sum(r["verts"] for r in rows),
       "total_polys": sum(r["polys"] for r in rows),
       ax + "_extent": [round(min(c[AXIS] for c in allc), 3),
                        round(max(c[AXIS] for c in allc), 3)],
       "z_extent": [round(min(c[2] for c in allc), 3),
                    round(max(c[2] for c in allc), 3)],
       "objects": rows}

# --- сверка с ожиданием ---
problems = []


def near(got, want, tol=0.02):
    return abs(got - want) <= tol


if "expect-objects" in A and int(A["expect-objects"]) != len(meshes):
    problems.append("объектов %d, ожидалось %s" % (len(meshes), A["expect-objects"]))
for flag, key in (("expect-x", ax + "_extent"), ("expect-z", "z_extent")):
    if flag in A:
        lo, hi = (float(v) for v in A[flag].split(":"))
        got = out[key]
        if not (near(got[0], lo) and near(got[1], hi)):
            problems.append("%s = %s, ожидалось %s" % (key, got, [lo, hi]))
if len(meshes) == 0:
    problems.append("FBX пуст — нечего проверять")

out["problems"] = problems
print("VERIFY_JSON=" + json.dumps(out, ensure_ascii=False))
print("VERDICT: " + ("PASS" if not problems else "FAIL -> " + "; ".join(problems)))