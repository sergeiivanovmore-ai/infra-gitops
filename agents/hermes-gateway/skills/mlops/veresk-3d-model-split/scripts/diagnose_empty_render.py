#!/usr/bin/env python3
"""Диагностика «предмет рендерится пустым».

Задача: отличить три причины, которые выглядят одинаково —
  1) камера промахнулась;
  2) удалены EMPTY-родители -> панели улетели на сотни единиц;
  3) в сцене реально нет геометрии предмета.

    LOR_FBX=input.fbx LOR_OUT=/work LOR_NUM=3 \
      blender --background --factory-startup --python diagnose_empty_render.py

Ключевая проверка — МИРОВОЙ BBOX СЦЕНЫ ПОСЛЕ ОЧИСТКИ, сравнить с габаритами
предмета из members. Если сцена в разы больше предмета -> удалены родители
(причина 2), чинить в batch_export_isolated.py, а не двигать камеру.

Дополнительно печатает подозрительные объекты: |location| > 50 (панели,
позиция которых вычисляется через EMPTY-родителя) и scale < 0.01.
"""
import bpy
import os
import json
from mathutils import Vector

FBX = os.environ["LOR_FBX"]
OUT = os.environ["LOR_OUT"]
NUM = os.environ.get("LOR_NUM", "1")

bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()
bpy.ops.import_scene.fbx(filepath=FBX)

idx = json.load(open(os.path.join(OUT, "items_index.json")))
by = {o.name: o for o in bpy.data.objects}
want = set(idx["members"][NUM])

present = [by[n] for n in idx["members"][NUM] if n in by]
for o in list(bpy.data.objects):
    if o.type != 'MESH' or o.name in want:
        continue
    bpy.data.objects.remove(o, do_unlink=True)
for o in bpy.data.objects:
    if o.type != 'MESH' and o.name not in want:
        o.hide_render = True
        o.hide_viewport = True

meshes = [o for o in bpy.data.objects if o.type == 'MESH']
print("ITEM=%s want=%d present=%d meshes_left=%d"
      % (NUM, len(want), len(present), len(meshes)), flush=True)


def bbox_of(objs):
    p = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    if not p:
        return None
    return [(min(q[i] for q in p), max(q[i] for q in p)) for i in range(3)]


item_bb = bbox_of(present)
scene_bb = bbox_of(meshes)
print("ПРЕДМЕТ bbox: %s" % (item_bb,), flush=True)
print("СЦЕНА  bbox: %s" % (scene_bb,), flush=True)

if item_bb and scene_bb:
    isize = max(item_bb[i][1] - item_bb[i][0] for i in range(3))
    ssize = max(scene_bb[i][1] - scene_bb[i][0] for i in range(3))
    print("РАЗМЕР предмета=%.3f  сцены=%.3f  отношение=%.1f"
          % (isize, ssize, ssize / max(isize, 1e-6)), flush=True)
    if ssize > max(isize * 3, isize + 5.0):
        print(">>> ВЕРДИКТ: удалены EMPTY-родители, геометрия улетела. "
              "Чинить удаление чужих объектов, НЕ камеру.", flush=True)
    elif isize < 1e-6:
        print(">>> ВЕРДИКТ: у предмета нет геометрии после очистки.", flush=True)
    else:
        print(">>> ВЕРДИКТ: bbox в норме — проверять материал/камеру/свет.", flush=True)

susp = []
for o in meshes:
    loc_far = max(abs(v) for v in o.location) > 50
    tiny = max(abs(s) for s in o.scale) < 0.01
    if loc_far or tiny:
        susp.append(o.name)
        print("  ПОДОЗР. %-24s loc=(%.2f,%.2f,%.2f) scale=(%.4f,%.4f,%.4f)"
              % (o.name, o.location.x, o.location.y, o.location.z,
                 o.scale.x, o.scale.y, o.scale.z), flush=True)
print("ПОДОЗРИТЕЛЬНЫХ=%d из %d" % (len(susp), len(meshes)), flush=True)