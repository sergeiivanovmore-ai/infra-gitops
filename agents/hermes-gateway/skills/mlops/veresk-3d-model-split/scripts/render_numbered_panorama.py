#!/usr/bin/env python3
"""Нумерованная панорама модели — ГЛАВНЫЙ инструмент для привязки к
порядковым номерам пользователя.

Что делает:
  1. Импортирует FBX ОДИН РАЗ.
  2. Кластеризует объекты по зазорам вдоль главной оси.
  3. Сливает вложенные артефакты (перегородки внутри шкафов и т.п.),
     чтобы нумерация совпала с ВИЗУАЛЬНЫМ счётом пользователя.
  4. Проставляет красный номер над каждым предметом.
  5. Рендерит N кадров по --per-slice предметов, переключая hide_render.

Использование:
    blender --background --python render_numbered_panorama.py -- \
        --input model.fbx --out-dir /tmp/panorama --per-slice 10

Запускать в фоне: на тяжёлой модели 10 кадров занимают минуты.
"""
import bpy, sys, os, argparse, math
from mathutils import Vector


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--out-dir", default="/tmp/panorama")
    p.add_argument("--per-slice", type=int, default=10)
    p.add_argument("--axis", type=int, default=-1, help="-1 = самая длинная ось")
    p.add_argument("--gap-tol", type=float, default=0.05)
    p.add_argument("--res-x", type=int, default=2400)
    p.add_argument("--res-y", type=int, default=620)
    p.add_argument("--samples", type=int, default=28)
    p.add_argument("--label-size", type=float, default=0.26)
    p.add_argument("--method", choices=("gap", "center"), default="gap",
                   help="gap — по зазорам bbox (разнесённые модули); "
                        "center — по координате ЦЕНТРОВ (перекрывающиеся объекты, "
                        "напр. распахнутые двери). См. references/overlapping_clusters.md")
    p.add_argument("--center-gap-thr", type=float, default=0.5,
                   help="порог разрыва между соседними центрами для --method center")
    p.add_argument("--fill", type=float, default=0.90,
                   help="доля кадра, занимаемая содержимым (аналитический кадр)")
    p.add_argument("--auto-aspect", type=int, default=1,
                   help="1 = подбирать высоту кадра под содержимое каждого слайса, "
                        "чтобы не было пустых полей по бокам")
    p.add_argument("--min-res-y", type=int, default=620)
    p.add_argument("--max-res-y", type=int, default=1500)
    p.add_argument("--only-slices", default="",
                   help="через запятую номера кадров 1-based, напр. '1,11,22' — "
                        "быстрый тест кадрирования без полного прогона")
    p.add_argument("--max-slices", type=int, default=0,
                   help="0 = все кадры; >0 — только первые N: проверка кадрирования "
                        "перед полным прогоном")
    return p.parse_args(argv)


def merge_nested(mods):
    """Кластер, полностью вложенный в соседний и в 2+ раза уже него —
    артефакт разбиения (перегородка/полка внутри корпуса). Сливаем обратно."""
    mods = sorted(mods, key=lambda m: m["x0"])
    out = []
    for m in mods:
        merged = False
        for o in out:
            if m["x0"] >= o["x0"] - 1e-6 and m["x1"] <= o["x1"] + 1e-6:
                ow, mw = o["x1"] - o["x0"], m["x1"] - m["x0"]
                if mw < ow * 0.5:
                    o["x0"] = min(o["x0"], m["x0"])
                    o["x1"] = max(o["x1"], m["x1"])
                    o["n"] += m["n"]
                    merged = True
                    break
        if not merged:
            out.append(dict(m))
    return out


def main():
    a = parse_args()

    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.curves):
        for b in list(coll):
            if b.users == 0:
                coll.remove(b)

    bpy.ops.import_scene.fbx(filepath=a.input)
    meshes = [o for o in bpy.context.scene.objects
              if o.type == 'MESH' and len(o.data.vertices)]
    print("MESH=%d" % len(meshes), flush=True)

    # bbox по мировым координатам
    bb = {}
    for o in meshes:
        cs = [o.matrix_world @ Vector(c) for c in o.bound_box]
        bb[o] = tuple(f(cs) for f in (
            lambda v: min(c[0] for c in v), lambda v: max(c[0] for c in v),
            lambda v: min(c[1] for c in v), lambda v: max(c[1] for c in v),
            lambda v: min(c[2] for c in v), lambda v: max(c[2] for c in v)))

    # главная ось
    if a.axis < 0:
        spans = {i: max(bb[o][i * 2 + 1] for o in meshes) - min(bb[o][i * 2] for o in meshes)
                 for i in range(3)}
        AX = max(spans, key=lambda i: spans[i])
    else:
        AX = a.axis
    print("AXIS=%d span=%.2f" % (AX, max(bb[o][AX * 2 + 1] for o in meshes)
                                 - min(bb[o][AX * 2] for o in meshes)), flush=True)

    def sx(o): return bb[o][AX * 2]
    def ex(o): return bb[o][AX * 2 + 1]
    def top(o): return bb[o][5]

    # кластеризация: сортируем ПО КООРДИНАТЕ (объекты в кортежах не сравниваются)
    #
    # Два метода. gap — по зазорам bbox: годится, когда модули стоят раздельно.
    # center — по координате центров: обязателен, когда объекты ПЕРЕКРЫВАЮТСЯ
    # вдоль оси (распахнутые двери заходят в диапазон соседа). При перекрытии
    # метод gap даёт пересекающиеся группы → при экспорте объекты задваиваются.
    if a.method == "center":
        order = sorted(meshes, key=lambda o: ((sx(o) + ex(o)) / 2.0, o.name))
        raw, cur = [], [order[0]]
        for p in order[1:]:
            cur.append(p)
            if ((sx(p) + ex(p)) / 2.0) - ((sx(cur[-2]) + ex(cur[-2])) / 2.0) > a.center_gap_thr:
                raw.append(cur); cur = [p]
        raw.append(cur)
    else:
        order = sorted(meshes, key=lambda o: (sx(o), ex(o), o.name))
        raw, cur = [], [order[0]]
        for p in order[1:]:
            cur.append(p)
            if sx(p) - ex(cur[-2]) > a.gap_tol:
                raw.append(cur); cur = [p]
        raw.append(cur)

    mods = [{"x0": min(sx(o) for o in g), "x1": max(ex(o) for o in g),
             "n": len(g), "objs": list(g)} for g in raw]
    n_raw = len(mods)
    for _ in range(5):
        nxt = merge_nested(mods)
        if len(nxt) == len(mods):
            break
        mods = nxt
    print("CLUSTERS=%d -> ПРЕДМЕТОВ=%d (слито артефактов: %d)"
          % (n_raw, len(mods), n_raw - len(mods)), flush=True)

    # материалы
    mat = bpy.data.materials.new('M'); mat.use_nodes = True
    b = mat.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (0.45, 0.46, 0.48, 1)
    b.inputs['Roughness'].default_value = 0.5
    lmat = bpy.data.materials.new('L'); lmat.use_nodes = True
    lb = lmat.node_tree.nodes['Principled BSDF']
    lb.inputs['Base Color'].default_value = (0.85, 0.08, 0.08, 1)
    lb.inputs['Roughness'].default_value = 0.6
    for o in meshes:
        o.data.materials.clear(); o.data.materials.append(mat)

    # Камера смотрит вдоль VIEW. Тем же вектором разворачиваем текстовые метки:
    # по умолчанию FONT лежит в плоскости XY (плашмя), и при изометрии цифры
    # видны с сильным сокращением — нечитаемо.
    VIEW = Vector((0.55, -0.62, 0.42)).normalized()
    LABEL_ROT = VIEW.to_track_quat('Z', 'Y').to_matrix()

    # метки
    labels = []
    for i, m in enumerate(mods):
        t = bpy.data.curves.new('T%d' % i, 'FONT')
        t.body = str(i + 1); t.size = a.label_size; t.extrude = 0.01
        t.align_x = 'CENTER'; t.align_y = 'CENTER'
        ob = bpy.data.objects.new('LBL%d' % i, t)
        bpy.context.collection.objects.link(ob)
        ob.location = ((m["x0"] + m["x1"]) / 2.0,
                       sum(bb[o][3] for o in m["objs"]) / len(m["objs"]),
                       max(top(o) for o in m["objs"]) + a.label_size * 1.4)
        ob.rotation_euler = LABEL_ROT.to_euler()   # цифра лицом к зрителю
        ob.data.materials.append(lmat)
        labels.append(ob)

    # свет + фон (явно: без этого кадр выжигается в белый)
    sd = bpy.data.lights.new('S', 'SUN'); sd.energy = 3.2
    so = bpy.data.objects.new('S', sd); bpy.context.collection.objects.link(so)
    so.rotation_euler = (math.radians(52), 0, math.radians(35))
    wd = bpy.data.worlds.new('W'); bpy.context.scene.world = wd; wd.use_nodes = True
    bg = wd.node_tree.nodes['Background']
    bg.inputs[0].default_value = (0.95, 0.96, 0.98, 1)
    bg.inputs[1].default_value = 1.2

    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.samples = a.samples
    sc.cycles.use_denoising = True
    sc.render.resolution_x = a.res_x
    sc.render.resolution_y = a.res_y
    sc.render.resolution_percentage = 100
    sc.view_settings.view_transform = 'Standard'
    sc.render.image_settings.file_format = 'PNG'

    tgt = bpy.data.objects.new('T', None); bpy.context.collection.objects.link(tgt)
    cd = bpy.data.cameras.new('C'); cam = bpy.data.objects.new('C', cd)
    bpy.context.collection.objects.link(cam)
    cd.type = 'PERSP'; cd.lens = 55; cd.clip_start = 0.01; cd.clip_end = 10000
    con = cam.constraints.new('TRACK_TO')
    con.target = tgt; con.track_axis = 'TRACK_NEGATIVE_Z'; con.up_axis = 'UP_Y'
    sc.camera = cam

    os.makedirs(a.out_dir, exist_ok=True)
    n_slices = (len(mods) + a.per_slice - 1) // a.per_slice
    if a.max_slices > 0:
        n_slices = min(n_slices, a.max_slices)
    only = {int(x) - 1 for x in a.only_slices.split(",") if x.strip()}

    # --- Аналитическое кадрирование -----------------------------------------
    # camera_to_view_selected() ненадёжен: в --background у Blender может не
    # быть 3D-окна, и кроме того оператор не учитывает перспективное
    # расширение по глубине — в изометрии ряд предметов идёт по диагонали,
    # и ближний конец выходит за нижний край кадра. Поэтому проецируем углы
    # bbox сами и итеративно подбираем дистанцию и смещение цели.
    #
    # ВАЖНО про вертикальный FOV: при sensor_fit='AUTO' и res_x > res_y
    # sensor_width отображается на ШИРИНУ кадра, поэтому
    #     полуширина = z * TAN_X,  полувысота = z * TAN_X / ASPECT
    # Ошибка «* ASPECT» вместо «/ ASPECT» завышает вертикальный обзор в
    # ASPECT раз (при 2600x760 — в 3.4 раза): по горизонтали кадр выглядит
    # идеально, а по вертикали содержимое вылезает за оба края.
    ASPECT = a.res_x / float(a.res_y)
    TAN_X = (cd.sensor_width / 2.0) / cd.lens

    def set_aspect(res_y):
        global ASPECT, TAN_Y
        sc.render.resolution_y = int(res_y)
        ASPECT = a.res_x / float(sc.render.resolution_y)
        TAN_Y = TAN_X / ASPECT

    def corners_of(ob):
        return [ob.matrix_world @ Vector(c) for c in ob.bound_box]

    def fit_camera(pts, fill=0.90, iters=80):
        """Дистанция + смещение цели так, чтобы pts легли в кадр.

        Возвращает (u0, u1, v0, v1) итоговой проекции для проверки.
        """
        if not pts:
            return (0.0, 1.0, 0.0, 1.0)
        d = max((p - tgt.location).length for p in pts) * 3.0
        u0, u1, v0, v1 = 0.0, 1.0, 0.0, 1.0
        for _ in range(iters):
            cam.location = tgt.location + VIEW * d
            bpy.context.view_layer.update()
            M = cam.matrix_world.inverted()
            us, vs, ds = [], [], []
            bad = False
            for p in pts:
                q = M @ p
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
            if abs(s - 1.0) < 0.002 and abs(du) < 0.002 and abs(dv) < 0.002:
                break
            zref = sum(ds) / len(ds)
            rot3 = cam.matrix_world.to_3x3()
            tgt.location = tgt.location \
                + (rot3 @ Vector((1.0, 0.0, 0.0))) * (du * 2.0 * zref * TAN_X) \
                + (rot3 @ Vector((0.0, 1.0, 0.0))) * (dv * 2.0 * zref * TAN_Y)
            d *= s
        return (u0, u1, v0, v1)

    set_aspect(a.res_y)
    worst = 1.0

    for s in range(n_slices):
        if only and s not in only:
            continue
        lo, hi = s * a.per_slice, min((s + 1) * a.per_slice, len(mods))
        sl = mods[lo:hi]
        x0 = min(m["x0"] for m in sl) - 0.25
        x1 = max(m["x1"] for m in sl) + 0.25

        for o in meshes:
            o.hide_render = not (ex(o) >= x0 and sx(o) <= x1)
        for i, lb in enumerate(labels):
            lb.hide_render = not (lo <= i < hi)

        zs = [max(top(o) for o in m["objs"]) for m in sl]
        top_z = max(zs) + a.label_size * 2
        ctr = Vector(((x0 + x1) / 2.0, 0.0, top_z / 2.0))
        tgt.location = ctr
        cam.location = ctr + VIEW * 3.0
        bpy.context.view_layer.update()

        pts = []
        for m in sl:
            for o in m["objs"]:
                pts.extend(corners_of(o))
        for i, lb in enumerate(labels):
            if lo <= i < hi:
                pts.extend(corners_of(lb))
        bpy.context.view_layer.update()

        u0, u1, v0, v1 = fit_camera(pts)

        # Пропорции кадра под содержимое: диагональный ряд в изометрии не
        # совпадает с фиксированным кадром, и по бокам остаётся пустое место.
        if a.auto_aspect:
            eu = max(u1 - u0, 1e-6)
            ev = max(v1 - v0, 1e-6)
            want_y = int(round(a.res_x * ev / eu))
            want_y = max(a.min_res_y, min(a.max_res_y, want_y))
            if abs(want_y - sc.render.resolution_y) > 8:
                set_aspect(want_y)
                u0, u1, v0, v1 = fit_camera(pts)

        worst = min(worst, u0, 1.0 - u1, v0, 1.0 - v1)

        out = os.path.join(a.out_dir, "pano_%02d_mod%03d-%03d.png" % (s + 1, lo + 1, hi))
        sc.render.filepath = out

        bpy.ops.render.render(write_still=True)
        print("SLICE %d/%d  X %.1f-%.1f  mods %d-%d  res %dx%d  "
              "frame u[%.3f..%.3f] v[%.3f..%.3f] -> %s"
              % (s + 1, n_slices, x0, x1, lo + 1, hi,
                 sc.render.resolution_x, sc.render.resolution_y,
                 u0, u1, v0, v1, out), flush=True)

    print("ALL_DONE worst_margin=%.3f" % worst, flush=True)


if __name__ == "__main__":
    main()