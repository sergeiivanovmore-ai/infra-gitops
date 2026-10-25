#!/usr/bin/env python3
"""Батч: разделить модель на предметы + отрендерить каждый. ОДИН импорт FBX.

Принимает JSON-конфиг после "--". Запускать через Blender:
    blender --background --python batch_split_render.py -- '{"fbx": ..., ...}'

Конфиг:
    fbx         исходный FBX
    index       items_index.json (после merge_nested!)
    parts_dir   куда экспортировать части
    renders_dir куда складывать рендеры
    report      JSON-отчёт (проверяется на assigned == meshes)
    samples,res рендер
    only        [опц.] список номеров предметов — прогон по подмножеству

Инварианты, которые скрипт обязан держать:
  * один импорт FBX на весь прогон (правило экономии токенов №1)
  * объект -> часть по ЦЕНТРУ, без дублей
  * печатает ASSIGNED=<n> of <m> meshes и MISSING= при нарушении
"""
import bpy, json, sys, os, math, time
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
C = json.loads(argv[0])

FBX = C["fbx"]
INDEX = C["index"]
OUT_PARTS = C["parts_dir"]
OUT_RENDERS = C["renders_dir"]
RES = C.get("res", 1024)
SAMPLES = C.get("samples", 128)
ONLY = C.get("only")
LENS = C.get("lens", 55)
DO_RENDER = C.get("render", True)
FILL = C.get("fill", 0.90)

os.makedirs(OUT_PARTS, exist_ok=True)
os.makedirs(OUT_RENDERS, exist_ok=True)

with open(INDEX) as f:
    idx = json.load(f)
items = idx["items"]
if ONLY:
    want = set(ONLY)
    items = [i for i in items if i["n"] in want]
print("ITEMS=%d" % len(items), flush=True)

# ---------------- импорт один раз ----------------
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()
for coll in (bpy.data.meshes, bpy.data.materials):
    for b in list(coll):
        if b.users == 0:
            coll.remove(b)
bpy.ops.import_scene.fbx(filepath=FBX)

meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH' and len(o.data.vertices)]
by_name = {}
for o in meshes:
    cs = [o.matrix_world @ Vector(c) for c in o.bound_box]
    x0 = min(c[0] for c in cs); x1 = max(c[0] for c in cs)
    by_name[o.name] = {"x0": x0, "x1": x1, "ctr": (x0 + x1) / 2.0, "obj": o}
print("MESH=%d" % len(meshes), flush=True)

# ---------------- материал ----------------
# Затемнённый нейтральный: при пересвете (Standard + сильный свет) светло-серый
# 0.45 выходит почти белым и форма шкафа теряется.
BASE_COLOR = C.get("base_color", 0.30)
_T0 = time.time()


def mark(stage):
    print("STAGE %-22s %.1f сек" % (stage, time.time() - _T0), flush=True)


mat = bpy.data.materials.new('M'); mat.use_nodes = True
b = mat.node_tree.nodes['Principled BSDF']
b.inputs['Base Color'].default_value = (BASE_COLOR, BASE_COLOR, BASE_COLOR * 1.04, 1)
b.inputs['Roughness'].default_value = 0.55
for o in meshes:
    o.data.materials.clear(); o.data.materials.append(mat)
mark("материалы x%d" % len(meshes))

# ---------------- свет + фон ----------------
sd = bpy.data.lights.new('S', 'SUN'); sd.energy = C.get("sun", 2.0)
so = bpy.data.objects.new('S', sd); bpy.context.collection.objects.link(so)
so.rotation_euler = (math.radians(52), 0, math.radians(35))
wd = bpy.data.worlds.new('W'); bpy.context.scene.world = wd; wd.use_nodes = True
bgn = wd.node_tree.nodes['Background']
bgn.inputs[0].default_value = (0.95, 0.96, 0.98, 1)
bgn.inputs[1].default_value = C.get("world", 0.7)
fd = bpy.data.lights.new('F', 'AREA'); fd.energy = C.get("area", 120); fd.size = 8
fo = bpy.data.objects.new('F', fd); bpy.context.collection.objects.link(fo)
fo.rotation_euler = (math.radians(40), 0, math.radians(-30))

# ---------------- камера ----------------
tgt = bpy.data.objects.new('T', None); bpy.context.collection.objects.link(tgt)
cd = bpy.data.cameras.new('C'); cam = bpy.data.objects.new('C', cd)
bpy.context.collection.objects.link(cam)
cd.type = 'PERSP'; cd.lens = LENS; cd.clip_start = 0.01; cd.clip_end = 10000
con = cam.constraints.new('TRACK_TO')
con.target = tgt; con.track_axis = 'TRACK_NEGATIVE_Z'; con.up_axis = 'UP_Y'
sc = bpy.context.scene
sc.camera = cam

sc.render.engine = 'CYCLES'
sc.cycles.samples = SAMPLES
sc.cycles.use_denoising = True
sc.render.resolution_x = RES; sc.render.resolution_y = RES
sc.render.resolution_percentage = 100
sc.view_settings.view_transform = 'Standard'
sc.render.image_settings.file_format = 'PNG'

win = bpy.context.window
area = next((a for a in win.screen.areas if a.type == 'VIEW_3D'), None)
sp_view = area.spaces.active if area else None
if sp_view:
    sp_view.camera = cam

# --- АНАЛИТИЧЕСКИЙ КАДР -------------------------------------------------
# camera_to_view_selected() в --background ненадёжен (может не выполниться без
# 3D-окна) и не учитывает перспективное расширение по глубине. Проецируем
# углы bbox сами и подбираем дистанцию + смещение цели итеративно.
# ВАЖНО: TAN_Y = TAN_X / ASPECT (делить). При sensor_fit='AUTO' и квадратном
# кадре ASPECT=1, ошибка не проявится — но всплывёт на нестандартных пропорциях.
ASPECT = RES / float(RES)
TAN_X = (cd.sensor_width / 2.0) / cd.lens
TAN_Y = TAN_X / ASPECT


def fit_camera(pts, fill=FILL, iters=60):
    """Подобрать дистанцию и смещение цели так, чтобы pts легли в кадр.

    ВАЖНО: матрица камеры считается ЗДЕСЬ, чистой математикой, без
    bpy.context.view_layer.update(). Камера всегда смотрит на цель из точки
    tgt + VIEW*d, поэтому направление -VIEW постоянно и поворот камеры не
    зависит от d. Раньше в цикле стоял view_layer.update() — на сцене с 2375
    объектами он занимает ~12 сек, а итераций до 80: на предмете с 176
    объектами один кадр уходил на 16 минут вместо 30 секунд.
    """
    if not pts:
        return (0.0, 1.0, 0.0, 1.0)
    rot = (-VIEW).to_track_quat('-Z', 'Y').to_matrix().to_4x4()
    d = max((p - tgt.location).length for p in pts) * 3.0
    u0, u1, v0, v1 = 0.0, 1.0, 0.0, 1.0
    for _ in range(iters):
        cam_pos = tgt.location + VIEW * d
        view_m = Matrix.Translation(cam_pos) @ rot
        view_m = view_m.inverted()
        us, vs, ds = [], [], []
        bad = False
        for p in pts:
            q = view_m @ p
            z = -q.z
            if z <= 1e-4:
                bad = True
                break
            us.append((q.x / (z * TAN_X)) * 0.5 + 0.5)
            vs.append((q.y / (z * TAN_Y)) * 0.5 + 0.5)
            ds.append(z)
        if bad:
            d *= 2.0
            continue
        u0, u1, v0, v1 = min(us), max(us), min(vs), max(vs)
        du = (u0 + u1) / 2.0 - 0.5
        dv = (v0 + v1) / 2.0 - 0.5
        s = max(u1 - u0, v1 - v0) / fill
        if abs(s - 1.0) < 0.003 and abs(du) < 0.003 and abs(dv) < 0.003:
            break
        zref = sum(ds) / len(ds)
        right = rot.to_3x3() @ Vector((1.0, 0.0, 0.0))
        up = rot.to_3x3() @ Vector((0.0, 1.0, 0.0))
        tgt.location = tgt.location + right * (du * 2.0 * zref * TAN_X) \
                                    + up * (dv * 2.0 * zref * TAN_Y)
        d *= s
    cam.location = tgt.location + VIEW * d      # единственное применение к сцене
    return (u0, u1, v0, v1)


used = set()
results = []
total = len(items)
VIEW = Vector((0.707, -0.707, 0.5)).normalized()   # направление от цели к камере
# ДОКАЧКА: предмет, у которого уже есть FBX (и PNG при render=1), пропускается.
# Без этого после падения на 100-м предмете пришлось бы с нуля перерендеривать
# все предыдущие. Готовые файлы считаются ТОЛЬКО если они непустые.
RESUME = C.get("resume", False)
skipped = 0
# Допуск по границам центров. В индексе c0/c1 хранятся с 4 знаками (погрешность
# до 5e-5), поэтому 1e-9 — в 50000 раз меньше погрешности, и объекты на краях
# кластера молча выпадали (на Дарио: №14 терял все 3 объекта). 1e-3 перекрывает
# округление с запасом и при этом безопасен: соседние кластеры разнесены минимум
# на center_gap_thr (0.5), поэтому пересечения быть не может.
EPS = C.get("bound_eps", 1e-3)

for idx_i, it in enumerate(items, 1):
    n = it["n"]; x0 = it["x0"]; x1 = it["x1"]
    # Назначение ТОЛЬКО по границам центров (c0/c1). Границы по bbox (x0/x1)
    # у соседей перекрываются из-за распахнутых дверей: предмет забирает
    # объекты следующего, тот выходит пустым. Проверено на Дарио — 18 пустых
    # частей из 88 при назначении по bbox.
    lo_c = it.get("c0", x0)
    hi_c = it.get("c1", x1)

    # докачка: файл уже есть — не пересчитываем
    fbx_p = os.path.join(OUT_PARTS, "%d.fbx" % n)
    png_p = os.path.join(OUT_RENDERS, "%d_iso.png" % n)
    if RESUME and os.path.exists(fbx_p) and os.path.getsize(fbx_p) > 0 \
            and (not DO_RENDER or (os.path.exists(png_p) and os.path.getsize(png_p) > 0)):
        sel = [v["obj"] for k, v in by_name.items()
               if v["ctr"] >= lo_c - EPS and v["ctr"] <= hi_c + EPS]
        for v in sel:
            used.add(v.name)
        results.append({"n": n, "objects": len(sel), "x0": x0, "x1": x1,
                        "fbx": fbx_p, "png": png_p if DO_RENDER else None,
                        "resumed": True})
        skipped += 1
        print("ITEM %d/%d n=%d objects=%d SKIP (уже готов)" %
              (idx_i, total, n, len(sel)), flush=True)
        continue

    sel = [v["obj"] for k, v in by_name.items()
           if v["ctr"] >= lo_c - EPS and v["ctr"] <= hi_c + EPS and k not in used]
    for v in sel:
        used.add(v.name)

    # самопроверка: кластер обязан отдать ровно столько объектов, сколько их было
    # при кластеризации. Меньше — потеря геометрии, больше — захват соседа.
    exp_obj = it.get("objects")
    if exp_obj is not None and len(sel) != exp_obj and sel:
        print("WARN n=%d получено %d, ожидалось %d" % (n, len(sel), exp_obj), flush=True)

    if not sel:
        # незакрытый дубликат номера, а не потеря геометрии
        print("ITEM %d/%d n=%d EMPTY" % (idx_i, total, n), flush=True)
        results.append({"n": n, "objects": 0})
        continue

    for o in meshes:
        v = by_name[o.name]
        o.hide_render = not (v["ctr"] >= lo_c - EPS and v["ctr"] <= hi_c + EPS)
    mark("hide_render x%d" % len(meshes))

    xs = [c for o in sel for c in
          (o.matrix_world @ Vector(bb) for bb in o.bound_box)]
    mn = Vector((min(c[0] for c in xs), min(c[1] for c in xs), min(c[2] for c in xs)))
    mx = Vector((max(c[0] for c in xs), max(c[1] for c in xs), max(c[2] for c in xs)))
    ctr = (mn + mx) / 2.0
    diag = max((mx - mn).x, (mx - mn).y, (mx - mn).z)
    tgt.location = ctr
    cam.location = ctr + VIEW * max(diag * 1.5, 2.5)
    fo.location = ctr + Vector((-5, -7, 8))

    # экспорт FBX: только выбранные объекты
    bpy.ops.object.select_all(action='DESELECT')
    mark("select_all DESELECT")
    for o in sel:
        o.select_set(True)
    bpy.context.view_layer.objects.active = sel[0]
    mark("select_set x%d" % len(sel))
    bpy.ops.export_scene.fbx(filepath=os.path.join(OUT_PARTS, "%d.fbx" % n),
                             use_selection=True, apply_unit_scale=True,
                             bake_space_transform=False, object_types={'MESH'},
                             mesh_smooth_type='FACE', path_mode='COPY',
                             embed_textures=False,
                             # Без этого FBX-экспортёр прогоняет ВСЕ экшены сцены на
                             # каждый объект. На Дарио их 674, и 176 объектов предмета 89
                             # с анимацией давали 779 сек на 40 объектах вместо 0.4 сек.
                             bake_anim=False, bake_anim_use_all_actions=False,
                             bake_anim_use_nla_strips=False,
                             bake_anim_force_startend_keying=False)
    mark("экспорт FBX n=%d (%d об.)" % (n, len(sel)))

    # кадр — аналитически (см. fit_camera выше)
    if DO_RENDER:
        pts = [c for o in sel for c in (o.matrix_world @ Vector(bb) for bb in o.bound_box)]
        u0, u1, v0, v1 = fit_camera(pts)   # update() делается внутри один раз

        png_path = os.path.join(OUT_RENDERS, "%d_iso.png" % n)
        sc.render.filepath = png_path
        bpy.ops.render.render(write_still=True)
        rng = "u[%.3f..%.3f] v[%.3f..%.3f]" % (u0, u1, v0, v1)
    else:
        png_path = None
        rng = "render=off"

    results.append({"n": n, "objects": len(sel), "x0": x0, "x1": x1,
                    "fbx": os.path.join(OUT_PARTS, "%d.fbx" % n), "png": png_path})
    print("ITEM %d/%d n=%d objects=%d X %.2f-%.2f %s -> %s" %
          (idx_i, total, n, len(sel), x0, x1, rng, os.path.basename(png_path or "")), flush=True)

missed = [k for k in by_name if k not in used]
print("ASSIGNED=%d of %d meshes" % (len(used), len(meshes)), flush=True)
if missed:
    print("MISSING=%d %s" % (len(missed), missed[:10]), flush=True)
empty = [r["n"] for r in results if r.get("objects", 0) == 0]
if empty:
    print("EMPTY_PARTS=%s" % empty, flush=True)

with open(C["report"], "w") as f:
    json.dump({"results": results, "assigned": len(used), "meshes": len(meshes),
               "missing": missed, "empty_parts": empty}, f, ensure_ascii=False, indent=1)
print("ALL_DONE items=%d assigned=%d empty=%d" %
      (len(results), len(used), len(empty)), flush=True)