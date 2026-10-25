"""
Blender: РЕНДЕР изометрии для каждой части.

Каждый FBX рендерится в ИЗОЛИРОВАННОЙ свежей сцене (clear_scene + импорт
только этого файла) — иначе объекты дублируются между рендерами.

Запуск:
  blender --background --python render_parts.py -- \
      --models-dir /path/to/models \
      --out-dir /path/to/renders \
      [--select 1,3,5] [--samples 128] [--res 1024] [--suffix _iso]

Печатает: RENDER_JSON {...}
"""

import json
import math
import os
import sys

import bpy

DEFAULTS = {
    "samples": 128,
    "res": 1024,
    "color": (0.8, 0.8, 0.8, 1.0),
    "roughness": 0.3,
    "sun_energy": 5.0,
    "sun_angle": (45.0, 30.0),
    "cam_dist_mult": 1.6,
    "cam_min_dist": 1.2,
    "cam_lens": 50.0,
}


def parse_args(argv):
    a = dict(DEFAULTS)
    a.update({"models_dir": "", "out_dir": "", "select": "", "suffix": "_iso",
              "res_w": 0, "res_h": 0, "slice": "", "range": "", "axis": "X", "view": "iso",
              "ticks": 0})
    i = 0
    while i < len(argv):
        k = argv[i]
        if k == "--models-dir":
            a["models_dir"] = argv[i + 1]; i += 2
        elif k == "--out-dir":
            a["out_dir"] = argv[i + 1]; i += 2
        elif k == "--select":
            a["select"] = argv[i + 1]; i += 2
        elif k == "--samples":
            a["samples"] = int(argv[i + 1]); i += 2
        elif k == "--res":
            a["res"] = int(argv[i + 1]); i += 2
        elif k == "--res-w":
            a["res_w"] = int(argv[i + 1]); i += 2
        elif k == "--res-h":
            a["res_h"] = int(argv[i + 1]); i += 2
        elif k == "--slice":
            a["slice"] = argv[i + 1]; i += 2
        elif k == "--range":
            a["range"] = argv[i + 1]; i += 2
        elif k == "--axis":
            a["axis"] = argv[i + 1]; i += 2
        elif k == "--view":
            a["view"] = argv[i + 1]; i += 2
        elif k == "--ticks":
            a["ticks"] = float(argv[i + 1]); i += 2
        elif k == "--suffix":
            a["suffix"] = argv[i + 1]; i += 2
        else:
            i += 1
    # квадрат по умолчанию, но можно задать панораму --res-w 3200 --res-h 640
    a["res_w"] = a["res_w"] or a["res"]
    a["res_h"] = a["res_h"] or a["res"]
    return a


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras,
                 bpy.data.lights):
        for blk in list(coll):
            if blk.users == 0:
                try:
                    coll.remove(blk)
                except Exception:
                    pass


def scene_bounds(objects):
    import mathutils
    lo = mathutils.Vector((float("inf"),) * 3)
    hi = mathutils.Vector((-float("inf"),) * 3)
    for o in objects:
        for c in o.bound_box:
            w = o.matrix_world @ mathutils.Vector(c)
            for i in range(3):
                lo[i] = min(lo[i], w[i])
                hi[i] = max(hi[i], w[i])
    if lo[0] == float("inf"):
        return mathutils.Vector((0, 0, 0)), mathutils.Vector((1, 1, 1))
    return lo, hi


def render_iso(model_path, out_png, cfg):
    import mathutils

    clear_scene()
    bpy.ops.import_scene.fbx(filepath=model_path)
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not objs:
        return False

    axis_idx = {"X": 0, "Y": 1, "Z": 2}.get(cfg.get("axis", "X"), 0)

    # глобальные границы ВСЕЙ модели — нужны для корректных координат меток
    g_lo, g_hi = scene_bounds(objs)
    full_range = (g_lo[axis_idx], g_hi[axis_idx])

    # --- срез: оставить только объекты в I-й полосе из N вдоль оси ---
    slice_info = None
    spec = (cfg.get("slice") or "").strip()
    rng = (cfg.get("range") or "").strip()

    if rng and ":" in rng:
        # точный диапазон координат: "11.5:12.5"
        try:
            ra, rb = [float(x) for x in rng.split(":", 1)]
            keep = []
            for o in objs:
                olo, ohi = scene_bounds([o])
                if ohi[axis_idx] >= ra and olo[axis_idx] <= rb:
                    keep.append(o)
            if keep:
                objs = keep
                slice_info = {"range": [ra, rb]}
        except Exception:
            slice_info = None
    elif spec and "/" in spec:
        try:
            si, sn = [int(x) for x in spec.split("/", 1)]
            bpy.ops.object.select_all(action="DESELECT")
            lo, hi = scene_bounds(objs)
            span = hi[axis_idx] - lo[axis_idx]
            a = lo[axis_idx] + span * si / sn
            b = lo[axis_idx] + span * (si + 1) / sn
            keep = []
            for o in objs:
                olo, ohi = scene_bounds([o])
                if ohi[axis_idx] >= a and olo[axis_idx] <= b:
                    keep.append(o)
            if keep:
                objs = keep
                slice_info = {"index": si, "of": sn, "from": round(a, 4), "to": round(b, 4)}
        except Exception:
            slice_info = None

    lo, hi = scene_bounds(objs)
    center = (lo + hi) / 2.0
    size = hi - lo
    max_dim = max(size.x, size.y, size.z) or 1.0

    add_axis_ticks(objs, cfg, center, size, full_range)

    # --- подгонка кадра под пропорции изображения ---
    # Для вытянутых моделей (напр. 134 x 1 x 2.7) нужен панорамный кадр,
    # иначе объект превращается в тонкую полоску.
    aspect = max(cfg["res_w"], 1) / float(max(cfg["res_h"], 1))
    view = (cfg.get("view") or "iso").lower()

    if view == "front":
        # Прямой вид спереди: ряд модулей виден "фронтально", без ухода вдаль.
        # Для длинных линейных моделей это единственный читаемый вариант.
        return _render_scene(objs, cfg, out_png, center,
                             center + mathutils.Vector(front_offset(size, aspect, cfg)))
    if view == "top":
        return _render_scene(objs, cfg, out_png, center,
                             center + mathutils.Vector(top_offset(size, aspect, cfg)))

    cam_loc = center + mathutils.Vector(dist_vec(max_dim, aspect, cfg, size))
    return _render_scene(objs, cfg, out_png, center, cam_loc)


def front_offset(size, aspect, cfg):
    """Смещение камеры для фронтального вида с вписыванием в кадр."""
    import math

    half_w = max(size.x, size.y, 1e-6) / 2.0
    half_h = max(size.z, 1e-6) / 2.0
    depth = max(size.y, 1.0)
    fov_x = 2.0 * math.atan(18.0 / cfg["cam_lens"])      # 18мм — половина сенсора
    if aspect < 1.0:
        fov_x = 2.0 * math.atan(18.0 * aspect / cfg["cam_lens"])
    need_w = half_w / math.tan(fov_x / 2.0)
    # по вертикали: fov_y = 2*atan(18*aspect/lens) для горизонтального сенсора
    fov_y = 2.0 * math.atan(18.0 * aspect / cfg["cam_lens"])
    need_h = half_h / math.tan(fov_y / 2.0)
    return (0.0, -(max(need_w, need_h) * 1.15 + depth), 0.0)


def top_offset(size, aspect, cfg):
    import math
    half_w = max(size.x, size.y, 1e-6) / 2.0
    fov_x = 2.0 * math.atan(18.0 / cfg["cam_lens"])
    d = half_w / math.tan(fov_x / 2.0) * 1.15
    return (0.0, 0.0, d)


def dist_vec(max_dim, aspect, cfg, size):
    """Вектор смещения камеры, дающий заполнение кадра."""

    # базовое расстояние — по максимальному размеру
    d = max(max_dim * cfg["cam_dist_mult"], cfg["cam_min_dist"])
    # если объект сильно вытянут, отодвигаем по диагонали, чтобы влез по ширине
    length = max(size.x, size.y) or 1.0
    if aspect >= 1.0:
        k = aspect / max(1.0, (length / max(size.z or 1.0, 1e-6)))
        d *= min(k, 4.0)
    return (d, -d, d / 1.4)


def add_axis_ticks(objs, cfg, center, size, full_range=None):
    """
    Разметка длины модели: вертикальные линии-метки с подписями через
    каждые N единиц вдоль главной оси. Позволяет пользователю указать
    нужный модуль КООРДИНАТОЙ, а не порядковым номером ("7-й слева"),
    что для длинных рядов неоднозначно.

    full_range — (lo, hi) по ВСЕЙ модели. Обязателен при срезах,
    иначе координаты меток отсчитывались бы заново от края среза.
    """
    step = float(cfg.get("ticks") or 0)
    if step <= 0:
        return 0

    axis_idx = {"X": 0, "Y": 1, "Z": 2}.get(cfg.get("axis", "X"), 0)
    if full_range:
        lo, hi = full_range
    else:
        lo = center[axis_idx] - size[axis_idx] / 2.0
        hi = center[axis_idx] + size[axis_idx] / 2.0

    # линии выше и ниже модели, чтобы не закрывать её
    z_top = center.z + size.z / 2.0 + 0.12 * max(size.z, 1.0)
    y_plane = center.y - (size.y / 2.0 + 0.35 * max(size.y, 1.0))

    n = int((hi - lo) / step) + 1
    for k in range(n):
        x = lo + k * step
        if x > hi:
            break

        # вертикальная линия-метка
        mesh = bpy.data.meshes.new("tick")
        mesh.from_pydata(
            [(x, y_plane, center.z - size.z * 0.75),
             (x, y_plane, z_top)],
            [], [],
        )
        mesh.update()
        ob = bpy.data.objects.new("tick", mesh)
        bpy.context.collection.objects.link(ob)

        # материал: яркая чёрточка
        mat = bpy.data.materials.new("TickMat")
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Base Color"].default_value = (0.9, 0.1, 0.1, 1)
        bsdf.inputs["Roughness"].default_value = 0.5
        mesh.materials.append(mat)

        # подпись с РЕАЛЬНОЙ координатой (не индексом k!)
        cu = bpy.data.curves.new("lbl", type="FONT")
        cu.body = ("%d" % round(x)) if step >= 1 else ("%.1f" % x)
        cu.size = 0.18 * max(size.z, 1.0)
        cu.extrude = 0.02
        lo_ob = bpy.data.objects.new("lbl", cu)
        bpy.context.collection.objects.link(lo_ob)
        lo_ob.location = (x, y_plane, z_top + cu.size * 0.25)
        lo_ob.rotation_euler = (1.5707963, 0.0, 0.0)   # лицом к камере (-Y)

        lm = bpy.data.materials.new("LblMat")
        lm.use_nodes = True
        lb = lm.node_tree.nodes["Principled BSDF"]
        lb.inputs["Base Color"].default_value = (0.05, 0.2, 0.95, 1)
        lb.inputs["Roughness"].default_value = 0.5
        cu.materials.append(lm)
    return n


def _render_scene(objs, cfg, out_png, center, cam_loc):
    import mathutils

    # Единый материал для консистентного вида
    mat = bpy.data.materials.new("VereskMat")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = cfg["color"]
    bsdf.inputs["Roughness"].default_value = cfg["roughness"]
    for o in objs:
        if o.data.materials:
            o.data.materials[0] = mat
        else:
            o.data.materials.append(mat)

    target = bpy.data.objects.new("Target", None)
    bpy.context.collection.objects.link(target)
    target.location = center

    cam_data = bpy.data.cameras.new("Cam")
    cam = bpy.data.objects.new("Cam", cam_data)
    bpy.context.collection.objects.link(cam)
    cam.data.type = "PERSP"
    cam.data.lens = cfg["cam_lens"]
    cam.location = cam_loc
    con = cam.constraints.new("TRACK_TO")
    con.target = target
    con.track_axis = "TRACK_NEGATIVE_Z"
    con.up_axis = "UP_Y"

    sun_data = bpy.data.lights.new("Sun", "SUN")
    sun = bpy.data.objects.new("Sun", sun_data)
    bpy.context.collection.objects.link(sun)
    sun.rotation_euler = (
        math.radians(cfg["sun_angle"][0]),
        math.radians(cfg["sun_angle"][1]),
        0.0,
    )
    sun.data.energy = cfg["sun_energy"]

    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.samples = cfg["samples"]
    sc.render.resolution_x = cfg["res_w"]
    sc.render.resolution_y = cfg["res_h"]
    sc.render.film_transparent = True
    sc.render.filepath = out_png
    sc.camera = cam

    bpy.ops.render.render(write_still=True)
    return os.path.exists(out_png)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    cfg = parse_args(argv)

    md, outd = cfg["models_dir"], cfg["out_dir"]
    if not md or not os.path.isdir(md):
        print("RENDER_JSON " + json.dumps({"error": "Нет папки с моделями: %s" % md},
                                          ensure_ascii=False))
        return
    os.makedirs(outd, exist_ok=True)

    files = sorted([f for f in os.listdir(md) if f.lower().endswith(".fbx")],
                   key=lambda s: (len(s), s))
    if cfg["select"].strip():
        wanted = {s.strip() for s in cfg["select"].split(",") if s.strip()}
        files = [f for f in files if os.path.splitext(f)[0] in wanted]

    results = []
    for f in files:
        base = os.path.splitext(f)[0]
        png = os.path.join(outd, base + cfg["suffix"] + ".png")
        ok = False
        err = None
        try:
            ok = render_iso(os.path.join(md, f), png, cfg)
        except Exception as e:  # noqa: BLE001
            err = str(e)
        results.append({"part": base, "fbx": f, "png": png if ok else None,
                        "ok": ok, "error": err})
        print("RENDERED %s -> %s ok=%s" % (base, png, ok))

    print("RENDER_JSON " + json.dumps(
        {"models_dir": md, "out_dir": outd, "count": len(results),
         "results": results}, ensure_ascii=False))


main()