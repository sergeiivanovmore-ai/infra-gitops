import bpy
import math
import os
import json

# ============================================================
# КОНФИГУРАЦИЯ РЕНДЕРА
# ============================================================
PARTS_DIR = "/opt/data/workspace/dsh_model_split/veresk2/model"
RENDER_DIR = "/opt/data/workspace/dsh_model_split/veresk2/render"

RESOLUTION = (1024, 1024)
SAMPLES = 128
CAMERA_ANGLE_DEG = (35.264, -45)  # изометрия: elevation, azimuth
CAMERA_LENS = 50                  # мм
CAMERA_SENSOR = 36.0              # мм (sensor_fit='AUTO')
FRAME_FILL = 0.82                 # доля кадра, которую должен занимать объект
MATERIAL_COLOR = (0.8, 0.8, 0.8, 1)
MATERIAL_ROUGHNESS = 0.3
SUN_ENERGY = 5
SUN_ANGLE_DEG = (45, 30)  # elevation, azimuth
# ============================================================

os.makedirs(RENDER_DIR, exist_ok=True)

with open(os.path.join(PARTS_DIR, "groups.json")) as f:
    groups = json.load(f)

import mathutils

# Полуполкадр угла обзора: sensor_fit='AUTO' для квадрата использует sensor_width
HALF_FOV = math.atan((CAMERA_SENSOR / 2.0) / CAMERA_LENS)


def scene_bbox(objects):
    """Габариты группы объектов в мировых координатах."""
    pts = []
    for ob in objects:
        for c in ob.bound_box:
            pts.append(ob.matrix_world @ mathutils.Vector(c))
    if not pts:
        return None
    mn = mathutils.Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = mathutils.Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return mn, mx


def render_iso(name, png):
    """Рендерит ВСЕ объекты группы, а не один.

    Дистанция камеры рассчитывается по радиусу bbox группы, поэтому предмет
    всегда занимает ~FRAME_FILL кадра независимо от его реального размера.
    """
    meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    if not meshes:
        print(f"SKIP {name}: нет меш-объектов")
        return

    # Единый материал на ВСЕ объекты (иначе видны штатные материалы модели)
    mat = bpy.data.materials.new('Mat')
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes['Principled BSDF']
    bsdf.inputs['Base Color'].default_value = MATERIAL_COLOR
    bsdf.inputs['Roughness'].default_value = MATERIAL_ROUGHNESS
    for ob in meshes:
        ob.data.materials.clear()
        ob.data.materials.append(mat)

    # Габариты всей группы → центр и радиус
    mn, mx = scene_bbox(meshes)
    center = (mn + mx) * 0.5
    radius = (mx - mn).length * 0.5

    # Пустой объект как цель камеры (в группе много объектов — целиться в один нельзя)
    target = bpy.data.objects.new('Target', None)
    target.empty_display_type = 'PLAIN_AXES'
    target.empty_display_size = 0.2
    target.location = center
    bpy.context.collection.objects.link(target)

    # Камера: изометрическая проекция, дистанция подгоняется под размер объекта
    cam_data = bpy.data.cameras.new('Cam')
    cam = bpy.data.objects.new('Cam', cam_data)
    bpy.context.collection.objects.link(cam)
    cam.data.type = 'PERSP'
    cam.data.lens = CAMERA_LENS
    cam.data.sensor_fit = 'AUTO'
    dist = (radius / math.sin(HALF_FOV)) / FRAME_FILL
    cam.data.clip_start = max(0.01, dist * 0.01)
    cam.data.clip_end = dist * 10

    el = math.radians(CAMERA_ANGLE_DEG[0])
    az = math.radians(CAMERA_ANGLE_DEG[1])
    cam.location = center + mathutils.Vector((
        math.cos(el) * math.sin(az + math.pi),
        -math.cos(el) * math.cos(az + math.pi),
        math.sin(el),
    )) * dist

    con = cam.constraints.new('TRACK_TO')
    con.target = target
    con.track_axis = 'TRACK_NEGATIVE_Z'
    con.up_axis = 'UP_Y'
    
    # Источник света (солнце)
    sun_data = bpy.data.lights.new('Sun', 'SUN')
    sun = bpy.data.objects.new('Sun', sun_data)
    bpy.context.collection.objects.link(sun)
    sun.rotation_euler = (
        math.radians(SUN_ANGLE_DEG[0]),
        math.radians(SUN_ANGLE_DEG[1]),
        0
    )
    sun.data.energy = SUN_ENERGY
    
    # Настройки рендера
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.samples = SAMPLES
    sc.cycles.use_denoising = True
    sc.render.resolution_x = RESOLUTION[0]
    sc.render.resolution_y = RESOLUTION[1]
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = True  # Прозрачный фон
    sc.render.filepath = png
    sc.camera = cam
    
    dims = mx - mn
    print(f"RENDER {name}: objs={len(meshes)} dims=({dims.x:.2f},{dims.y:.2f},{dims.z:.2f}) "
          f"radius={radius:.3f} dist={dist:.2f}", flush=True)
    bpy.ops.render.render(write_still=True)
    print(f"DONE {png}", flush=True)

# Обрабатываем каждую модель
def clear_scene():
    """Полная очистка сцены перед загрузкой следующей части."""
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()


for name in groups.keys():
    fbx = os.path.join(PARTS_DIR, f"{name}.fbx")
    png = os.path.join(RENDER_DIR, f"{name}_iso.png")

    clear_scene()

    # Загружаем FBX — вся группа объектов рендерится вместе
    bpy.ops.import_scene.fbx(filepath=fbx)

    render_iso(name, png)
    print(f"Rendered {png}")

print("Rendering complete!")