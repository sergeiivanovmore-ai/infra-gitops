#!/usr/bin/env python3
"""Экспорт + изометрия ОДНОГО предмета (безопасно для длинных прогонов).

Запускать в отдельном процессе Blender на каждый предмет — иначе память
растёт от повторного импорта FBX и прогон умирает с OOM (EXIT=137).

    LOR_FBX=input.fbx LOR_OUT=/work LOR_ONLY=28 \
      blender --background --factory-startup --python batch_export_isolated.py

Аргументы — через переменные окружения: разделитель `--` в hermes-прогоне
переставляется, и blender читает свои же флаги как имена файлов.

Читает items_index.json из LOR_OUT:
    {"n": 42, "merged": {...}, "members": {"1": ["ObjectName", ...], ...}}

Критично (см. references/batch_render_pitfalls.md):
  * рендер не знает про use_selection — удалить чужие объекты ДО рендера;
  * удалять только MESH: EMPTY-родители держат мировые трансформации панелей,
    их удаление уводит геометрию на сотни единиц и предмет рендерится пустым.
"""
import bpy
import os
import math
import json
from mathutils import Vector

FBX = os.environ["LOR_FBX"]
OUT = os.environ["LOR_OUT"]
ONLY = os.environ.get("LOR_ONLY", "")
SAMPLES = int(os.environ.get("LOR_SAMPLES", "64"))
RES = int(os.environ.get("LOR_RES", "1024"))

PARTS = os.path.join(OUT, "parts")
RENDERS = os.path.join(OUT, "renders")
os.makedirs(PARTS, exist_ok=True)
os.makedirs(RENDERS, exist_ok=True)

groups = json.load(open(os.path.join(OUT, "items_index.json")))
by_num = {}
for num, members in groups["members"].items():
    n = int(num)
    src = [g["src"] for g in groups["groups"] if g["n"] == n][0]
    by_num[n] = {"n": n, "src": src, "members": members}

todo = sorted(by_num.values(), key=lambda g: g["n"])
if ONLY:
    want = set(int(x) for x in ONLY.split(","))
    todo = [g for g in todo if g["n"] in want]

EXPORT_KW = dict(
    bake_anim=False,              # только у ЭКСПОРТА; у импорта такого ключа нет
    bake_anim_use_all_actions=False,
    bake_anim_use_nla_strips=False,
    object_types={'MESH'},
    use_mesh_modifiers=True,
)


def clear_scene():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()
    for act in list(bpy.data.actions):
        bpy.data.actions.remove(act)


def make_material():
    m = bpy.data.materials.get("RenderMat")
    if m is None:
        m = bpy.data.materials.new("RenderMat")
        m.use_nodes = True
        b = m.node_tree.nodes.get("Principled BSDF")
        b.inputs["Base Color"].default_value = (0.85, 0.80, 0.72, 1)
        b.inputs["Roughness"].default_value = 0.35
    return m


assigned = 0
empty = []

for g in todo:
    clear_scene()
    bpy.ops.import_scene.fbx(filepath=FBX)

    by_name = {o.name: o for o in bpy.data.objects}
    want = set(g["members"])
    present = [by_name[n] for n in g["members"] if n in by_name]

    # удалять ТОЛЬКО чужие MESH: EMPTY-родители держат трансформации детей
    for o in list(bpy.data.objects):
        if o.type != 'MESH' or o.name in want:
            continue
        bpy.data.objects.remove(o, do_unlink=True)

    # остальное (EMPTY и пр.) — скрыть, но НЕ удалять
    for o in bpy.data.objects:
        if o.type != 'MESH' and o.name not in want:
            o.hide_render = True
            o.hide_viewport = True

    if not present:
        empty.append(g["n"])
        print("ITEM %d EMPTY (нет объектов по именам)" % g["n"], flush=True)
        continue

    mat = make_material()
    for o in present:
        o.data.materials.clear()
        o.data.materials.append(mat)

    bpy.ops.object.select_all(action='DESELECT')
    for o in bpy.data.objects:
        o.select_set(False)
    for o in present:
        o.select_set(True)
    bpy.context.view_layer.objects.active = present[0]

    pts = [o.matrix_world @ Vector(c) for o in present for c in o.bound_box]
    bx0, bx1 = min(p.x for p in pts), max(p.x for p in pts)
    by0, by1 = min(p.y for p in pts), max(p.y for p in pts)
    bz0, bz1 = min(p.z for p in pts), max(p.z for p in pts)
    ctr = Vector(((bx0 + bx1) / 2, (by0 + by1) / 2, (bz0 + bz1) / 2))
    size = max(bx1 - bx0, by1 - by0, bz1 - bz0, 0.3)

    assigned += len(present)
    bpy.ops.export_scene.fbx(filepath=os.path.join(PARTS, "%d.fbx" % g["n"]),
                             use_selection=True, **EXPORT_KW)

    # камера по bbox предмета, а не фиксированная дистанция
    cam_d = bpy.data.cameras.new("Cam")
    cam_d.type = 'PERSP'
    cam_d.lens = 50
    cam = bpy.data.objects.new("Cam", cam_d)
    bpy.context.collection.objects.link(cam)
    d = size * 2.1
    cam.location = (ctr.x + d * 0.72, ctr.y - d * 0.92, ctr.z + d * 0.58)
    con = cam.constraints.new('TRACK_TO')
    tgt = bpy.data.objects.new("Tgt", None)
    tgt.location = ctr
    bpy.context.collection.objects.link(tgt)
    con.target = tgt
    con.track_axis = 'TRACK_NEGATIVE_Z'
    con.up_axis = 'UP_Y'

    for nm, energy, rx, rz in (("Key", 3.5, 52, 38), ("Fill", 1.4, 115, -125)):
        ld = bpy.data.lights.new(nm, 'SUN')
        ld.energy = energy
        lo = bpy.data.objects.new(nm, ld)
        bpy.context.collection.objects.link(lo)
        lo.rotation_euler = (math.radians(rx), 0, math.radians(rz))

    sc = bpy.context.scene
    sc.camera = cam
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = SAMPLES
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 4
    sc.render.resolution_x = RES
    sc.render.resolution_y = RES
    sc.world.node_tree.nodes["Background"].inputs[0].default_value = (0.96, 0.96, 0.97, 1)
    sc.render.filepath = os.path.join(RENDERS, "%d_iso.png" % g["n"])

    bpy.ops.render.render(write_still=True)
    print("ITEM %d n=%d objects=%d X %.2f-%.2f -> %d_iso.png"
          % (g["n"], g["n"], len(present), bx0, bx1, g["n"]), flush=True)

print("ASSIGNED=%d EMPTY=%s" % (assigned, empty), flush=True)
print("ALL_DONE items=%d assigned=%d empty=%d" % (len(todo), assigned, len(empty)), flush=True)