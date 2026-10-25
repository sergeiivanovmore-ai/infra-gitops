#!/usr/bin/env python3
"""Чистый изометрический рендер ОДНОГО диапазона X.

Сцена изолируется: импорт FBX -> удаление всего вне диапазона -> кадр.
Использовать для показа выбранного диапазона пользователю ДО загрузки на
Drive (правило «покажи и дождись подтверждения»).

    blender --background --python render_item_range.py -- \
        --input model.fbx --out /tmp/item15.png --x0 22.98 --x1 24.61

Важно: диапазон включает объекты, bbox которых ПЕРЕСЕКАЕТ [x0, x1], поэтому
кадр может быть шире запрошенного — это ожидаемо, не ошибка.
"""
import bpy, sys, os, math, argparse
from mathutils import Vector


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--x0", type=float, required=True)
    p.add_argument("--x1", type=float, required=True)
    p.add_argument("--axis", type=int, default=-1)
    p.add_argument("--res", type=int, default=1024)
    p.add_argument("--samples", type=int, default=128)
    return p.parse_args(argv)


def fit_camera(sc, cam, tgt, res):
    """Точный кадр встроенным оператором. Без этих строк в --background
    оператор падает с 'No active camera'."""
    bpy.ops.object.select_all(action='DESELECT')
    for o in sc.objects:
        o.select_set(True)
    sc.camera = cam
    bpy.context.view_layer.objects.active = cam
    win = bpy.context.window
    area = next((a for a in win.screen.areas if a.type == 'VIEW_3D'), None)
    if not area:
        return False
    reg = next(r for r in area.regions if r.type == 'WINDOW')
    sp = area.spaces.active
    sp.camera = cam
    with bpy.context.temp_override(window=win, area=area, region=reg,
                                  space_data=sp, scene=sc,
                                  view_layer=bpy.context.view_layer):
        bpy.ops.view3d.camera_to_view_selected()
    return True


def main():
    a = parse_args()

    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()
    for coll in (bpy.data.meshes, bpy.data.materials):
        for b in list(coll):
            if b.users == 0:
                coll.remove(b)

    bpy.ops.import_scene.fbx(filepath=a.input)
    meshes = [o for o in bpy.context.scene.objects
              if o.type == 'MESH' and len(o.data.vertices)]

    AX = a.axis
    if AX < 0:
        def span(i):
            cs = [c for o in meshes for c in
                  [o.matrix_world @ Vector(b) for b in o.bound_box]]
            return max(c[i] for c in cs) - min(c[i] for c in cs)
        AX = max(range(3), key=span)

    keep, allc = [], []
    for o in meshes:
        cs = [o.matrix_world @ Vector(c) for c in o.bound_box]
        cmin, cmax = min(c[AX] for c in cs), max(c[AX] for c in cs)
        if cmax >= a.x0 - 0.02 and cmin <= a.x1 + 0.02:
            keep.append(o); allc += cs
        else:
            bpy.data.objects.remove(o, do_unlink=True)
    print("KEEP=%d/%d" % (len(keep), len(meshes)), flush=True)
    if not keep:
        print("NOTHING_TO_RENDER"); return

    mat = bpy.data.materials.new('M'); mat.use_nodes = True
    b = mat.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (0.45, 0.46, 0.48, 1)
    b.inputs['Roughness'].default_value = 0.5
    for o in keep:
        o.data.materials.clear(); o.data.materials.append(mat)

    mn = Vector((min(c[0] for c in allc), min(c[1] for c in allc), min(c[2] for c in allc)))
    mx = Vector((max(c[0] for c in allc), max(c[1] for c in allc), max(c[2] for c in allc)))
    ctr = (mn + mx) / 2.0
    print("BBOX %.3f x %.3f x %.3f" % (mx.x - mn.x, mx.y - mn.y, mx.z - mn.z), flush=True)

    tgt = bpy.data.objects.new('T', None); bpy.context.collection.objects.link(tgt)
    tgt.location = ctr
    cd = bpy.data.cameras.new('C'); cam = bpy.data.objects.new('C', cd)
    bpy.context.collection.objects.link(cam)
    cd.type = 'PERSP'; cd.lens = 55; cd.clip_start = 0.01; cd.clip_end = 10000
    diag = max((mx - mn).x, (mx - mn).y, (mx - mn).z)
    view = Vector((0.707, -0.707, 0.5)).normalized()
    cam.location = ctr + view * max(diag * 1.5, 2.5)
    con = cam.constraints.new('TRACK_TO')
    con.target = tgt; con.track_axis = 'TRACK_NEGATIVE_Z'; con.up_axis = 'UP_Y'

    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.samples = a.samples
    sc.cycles.use_denoising = True
    sc.render.resolution_x = a.res
    sc.render.resolution_y = a.res
    sc.render.resolution_percentage = 100
    sc.view_settings.view_transform = 'Standard'
    sc.render.filepath = a.out
    sc.render.image_settings.file_format = 'PNG'

    # свет: задаём явно, иначе кадр выжигается в белый
    sd = bpy.data.lights.new('S', 'SUN'); sd.energy = 3.2
    so = bpy.data.objects.new('S', sd); bpy.context.collection.objects.link(so)
    so.rotation_euler = (math.radians(52), 0, math.radians(35))
    fd = bpy.data.lights.new('F', 'AREA'); fd.energy = 400; fd.size = 8
    fo = bpy.data.objects.new('F', fd); bpy.context.collection.objects.link(fo)
    fo.location = ctr + Vector((-5, -7, 8))
    fo.rotation_euler = (math.radians(40), 0, math.radians(-30))
    wd = bpy.data.worlds.new('W'); sc.world = wd; wd.use_nodes = True
    bg = wd.node_tree.nodes['Background']
    bg.inputs[0].default_value = (0.95, 0.96, 0.98, 1)
    bg.inputs[1].default_value = 1.2

    if fit_camera(sc, cam, tgt, a.res):
        print("FIT_OK", flush=True)
    bpy.ops.render.render(write_still=True)
    print("RENDERED=%s" % a.out, flush=True)


if __name__ == "__main__":
    main()