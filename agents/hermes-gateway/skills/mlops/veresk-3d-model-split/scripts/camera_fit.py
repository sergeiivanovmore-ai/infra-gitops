"""Точное кадрирование камеры для Blender — каноническая реализация.

ЕДИНЫЙ источник правды для расчёта кадра. Не копируй математику из скрипта в
скрипт: ошибка в `TAN_Y` (см. ниже) уже расходилась по трём копиям.

Зачем это нужно
---------------
Встроенный `bpy.ops.view3d.camera_to_view_selected()` ненадёжен:

1. В `--background` у Blender может не быть 3D-окна — оператор **не выполнится
   вовсе**, скрипт отрендерит с исходной дистанцией.
2. Он **не учитывает перспективное расширение по глубине**: в изометрии ряд
   предметов идёт по диагонали, ближние предметы крупнее и вылезают за край.

Правильный способ — спроецировать углы bbox самому и итеративно подобрать
дистанцию до камеры и смещение цели.

🚨 ОШИБКА, СТОЯВШАЯ ДОРОГО: направление деления на ASPECT
----------------------------------------------------------
При `sensor_fit='AUTO'` и `res_x > res_y` `sensor_width` отображается на
**ширину** кадра. Значит:

    полуширина = z * TAN_X
    полувысота = z * TAN_X / ASPECT      ← ДЕЛИТЬ

Ошибка `z * TAN_X * ASPECT` завышает вертикальный обзор в ASPECT раз
(при 2600×760 — в 3.4 раза). Она коварна: **по горизонтали кадр выглядит
идеально** (`u[0.050..0.950]` — ровно под `fill`), а по вертикали содержимое
вылезает за оба края. Лог показывает «правильный» результат, поэтому дефект
ловится ТОЛЬКО глазами на рендере.

Делить на ASPECT нужно в трёх местах: проекция `v`, сдвиг цели по вертикали,
пересчёт при смене пропорций кадра.

Использование
-------------
    import sys
    sys.path.insert(0, "/opt/data/skills/mlops/veresk-3d-model-split/scripts")
    from camera_fit import CameraFitter

    fit = CameraFitter(cam, tgt, res_x=2600, res_y=760, lens=cam.data.lens,
                       view=Vector((0.45, -0.70, 0.38)).normalized(), fill=0.90)
    u0, u1, v0, v1 = fit.fit(pts)          # pts — углы bbox мешей И меток
    if auto_aspect:
        fit.set_res_y(2600 * (v1 - v0) / (u1 - u0))
        u0, u1, v0, v1 = fit.fit(pts)

`worst_margin = min(u0, 1-u1, v0, 1-v1)` ≈ 0.05 — содержимое вписано с полями.
"""

import bpy
from mathutils import Vector


class CameraFitter:
    """Подбирает дистанцию и смещение цели так, чтобы точки легли в кадр."""

    def __init__(self, cam, tgt, res_x, res_y, lens, view, fill=0.90, iters=80):
        self.cam = cam
        self.tgt = tgt
        self.res_x = int(res_x)
        self.lens = lens
        self.view = Vector(view).normalized()
        self.fill = fill
        self.iters = iters
        # sensor_fit='AUTO': sensor_width отображается на ширину при res_x > res_y
        self.tan_x = (cam.data.sensor_width / 2.0) / lens
        self.set_res_y(res_y)

    def set_res_y(self, res_y):
        """Смена пропорций кадра. ОБЯЗАТЕЛЬНО перекадрируй после вызова."""
        self.res_y = int(res_y)
        bpy.context.scene.render.resolution_x = self.res_x
        bpy.context.scene.render.resolution_y = self.res_y
        self.aspect = self.res_x / float(self.res_y)
        self.tan_y = self.tan_x / self.aspect      # ← ДЕЛИТЬ, не умножать

    @staticmethod
    def corners_of(obj):
        return [obj.matrix_world @ Vector(c) for c in obj.bound_box]

    def fit(self, pts):
        """Возвращает (u0, u1, v0, v1) — границы проекции содержимого."""
        if not pts:
            return (0.0, 1.0, 0.0, 1.0)
        d = max((p - self.tgt.location).length for p in pts) * 3.0
        u0, u1, v0, v1 = 0.0, 1.0, 0.0, 1.0
        for _ in range(self.iters):
            self.cam.location = self.tgt.location + self.view * d
            bpy.context.view_layer.update()
            M = self.cam.matrix_world.inverted()
            us, vs, ds = [], [], []
            bad = False
            for p in pts:
                q = M @ p
                z = -q.z
                if z <= 1e-4:          # точка за камерой — отойдём подальше
                    bad = True
                    break
                us.append((q.x / (z * self.tan_x)) * 0.5 + 0.5)
                vs.append((q.y / (z * self.tan_y)) * 0.5 + 0.5)
                ds.append(z)
            if bad:
                d *= 2.0
                continue
            u0, u1, v0, v1 = min(us), max(us), min(vs), max(vs)
            du = (u0 + u1) / 2.0 - 0.5          # увести содержимое в центр кадра
            dv = (v0 + v1) / 2.0 - 0.5
            s = max(u1 - u0, v1 - v0) / self.fill
            if abs(s - 1.0) < 0.002 and abs(du) < 0.002 and abs(dv) < 0.002:
                break
            zref = sum(ds) / len(ds)
            r3 = self.cam.matrix_world.to_3x3()
            self.tgt.location = (self.tgt.location
                                 + (r3 @ Vector((1.0, 0.0, 0.0))) * (du * 2.0 * zref * self.tan_x)
                                 + (r3 @ Vector((0.0, 1.0, 0.0))) * (dv * 2.0 * zref * self.tan_y))
            d *= s
        return (u0, u1, v0, v1)

    @staticmethod
    def margin(u0, u1, v0, v1):
        """Запас вписывания: ~0.05 — хорошо, 0 — содержимое впритык к краю."""
        return min(u0, 1.0 - u1, v0, 1.0 - v1)

    @staticmethod
    def auto_res_y(res_x, u0, u1, v0, v1, min_res_y=620, max_res_y=1500):
        """Пропорции кадра под содержимое: диагональный ряд в изометрии не
        совпадает с фиксированным кадром — без этого по бокам пустые поля.
        Ограничители обязательны: одиночный предмет дал бы тысячи пикселей."""
        eu = max(u1 - u0, 1e-6)
        ev = max(v1 - v0, 1e-6)
        want = int(round(res_x * ev / eu))
        return max(min_res_y, min(max_res_y, want))


# ── освещение: не пересвечивать рендеры ────────────────────────────────────
# При view_transform='Standard' связка «серый 0.45 + SUN 3.2 + AREA 400 +
# world 1.2» даёт почти белый кадр: форма шкафа, дверей и ручек теряется.
# Проверено на Дарио — эти значения читались, дефект был виден только глазами.
LIGHT_DEFAULTS = {
    "base_color": 0.30,   # нейтральный серый; было 0.45 -> выбеливало
    "sun": 2.0,           # было 3.2
    "area": 120,          # было 400
    "world": 0.7,         # было 1.2
}


def apply_neutral_look(meshes, light_overrides=None):
    """Назначить всем мешам материал + свет + фон без пересвета."""
    cfg = dict(LIGHT_DEFAULTS)
    if light_overrides:
        cfg.update(light_overrides)
    bc = cfg["base_color"]

    mat = bpy.data.materials.new('M')
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes['Principled BSDF']
    bsdf.inputs['Base Color'].default_value = (bc, bc, bc * 1.04, 1)
    bsdf.inputs['Roughness'].default_value = 0.55
    for o in meshes:
        o.data.materials.clear()
        o.data.materials.append(mat)

    import math
    sc = bpy.context.scene
    sd = bpy.data.lights.new('S', 'SUN'); sd.energy = cfg["sun"]
    so = bpy.data.objects.new('S', sd); bpy.context.collection.objects.link(so)
    so.rotation_euler = (math.radians(52), 0, math.radians(35))

    fd = bpy.data.lights.new('F', 'AREA'); fd.energy = cfg["area"]; fd.size = 8
    fo = bpy.data.objects.new('F', fd); bpy.context.collection.objects.link(fo)
    fo.rotation_euler = (math.radians(40), 0, math.radians(-30))

    wd = bpy.data.worlds.new('W'); sc.world = wd; wd.use_nodes = True
    bg = wd.node_tree.nodes['Background']
    bg.inputs[0].default_value = (0.95, 0.96, 0.98, 1)
    bg.inputs[1].default_value = cfg["world"]

    sc.view_settings.view_transform = 'Standard'
    return so, fo