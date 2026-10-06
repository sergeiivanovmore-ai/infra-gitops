"""Диагностика зависания export_scene.fbx на одном предмете.

Запуск:
  blender --background --factory-startup --python diag_export_hang.py -- \
    '{"fbx":"/path/model.fbx","index":"/path/items_index.json","item":"89",
      "out":"/tmp/vil/exp89"}'

ВАЖНО: запускать на ТОЙ ЖЕ модели, где наблюдалось зависание. Проверка на
другой модели даёт ложный вывод «зависания нет» (в этой задаче: экспорт
стабильно работал на Penaly со 110 объектами, но вставал на Dario с 2375).

Печатает строку ДО каждого экспорта — по логу видно, на каком шаге встали.
"""
import bpy, json, sys, os, time
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
C = json.loads(argv[0])

t0 = time.time()
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()
bpy.ops.import_scene.fbx(filepath=C["fbx"])
bpy.context.view_layer.update()
print("IMPORT_OK %.1f сек" % (time.time() - t0), flush=True)

meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH' and len(o.data.vertices)]
by = {}
for o in meshes:
    cs = [o.matrix_world @ Vector(c) for c in o.bound_box]
    by[o.name] = {"ctr": (min(c[0] for c in cs) + max(c[0] for c in cs)) / 2.0, "obj": o}

# ключи приводим к int — иначе KeyError: '89' при C["item"]=="89"
items = {int(i["n"]): i for i in json.load(open(C["index"]))["items"]}
it = items[int(C["item"])]

sel = [v["obj"] for v in by.values()
       if v["ctr"] >= it["c0"] - 1e-3 and v["ctr"] <= it["c1"] + 1e-3]
sel.sort(key=lambda o: o.name)
print("MESH_TOTAL=%d  в предмете: об=%d верт=%d пол=%d uv=%d"
      % (len(meshes), len(sel),
         sum(len(o.data.vertices) for o in sel),
         sum(len(o.data.polygons) for o in sel),
         sum(len(o.data.uv_layers) for o in sel)), flush=True)

print("ТОП-5 по геометрии (верт, пол, uv, имя):", flush=True)
for v, p, u, n in sorted(((len(o.data.vertices), len(o.data.polygons),
                           len(o.data.uv_layers), o.name) for o in sel),
                         reverse=True)[:5]:
    print("   %7d %7d %4d  %s" % (v, p, u, n), flush=True)

out = C.get("out", "/tmp/vil/exp89")
os.makedirs(out, exist_ok=True)


def try_export(objs, path, label):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    print(">>> НАЧАЛ %s (об=%d)" % (label, len(objs)), flush=True)
    t = time.time()
    bpy.ops.export_scene.fbx(filepath=path, use_selection=True)
    print("<<< ГОТОВО %s %.2f сек %d байт"
          % (label, time.time() - t, os.path.getsize(path)), flush=True)


# 1. Нарастающий объём — ищем порог, где начинается вставать
for take in [40, 80, 120, len(sel)]:
    if take <= len(sel):
        try_export(sel[:take], os.path.join(out, "n%d.fbx" % take),
                   "первые %d" % take)

# 2. Полный набор со снятыми лишними UV-слоями — отделяем UV от объёма
for o in sel:
    while len(o.data.uv_layers) > 1:
        o.data.uv_layers.remove(o.data.uv_layers[-1])
try_export(sel, os.path.join(out, "nouv.fbx"), "все %d, 1 UV" % len(sel))
print("DIAG_DONE", flush=True)