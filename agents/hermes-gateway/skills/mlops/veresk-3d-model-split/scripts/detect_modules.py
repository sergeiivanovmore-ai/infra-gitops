"""
Blender: поиск отдельных предметов мебели внутри сцены (модулей).

Зазоры между модулями часто отсутствуют (мебель стоит вплотную), поэтому
разрезать по зазорам нельзя. Вместо этого объединяем объекты в группы
по ПЕРЕКРЫТИЮ их габаритов: панели одного шкафа перекрываются/касаются,
а два соседних шкафа лишь примыкают — перекрытия нет.

Запуск:
  blender --background --python detect_modules.py -- --input model.fbx [--merge-eps 0.01]

Печатает: MODULES_JSON {...}
"""

import json
import os
import sys

import bpy
import mathutils


def parse_args(argv):
    a = {"input": "", "merge_eps": 0.01, "cover": 0.98}
    i = 0
    while i < len(argv):
        k = argv[i]
        if k == "--input":
            a["input"] = argv[i + 1]; i += 2
        elif k == "--merge-eps":
            a["merge_eps"] = float(argv[i + 1]); i += 2
        elif k == "--cover":
            a["cover"] = float(argv[i + 1]); i += 2
        else:
            i += 1
    return a


def obj_box(o):
    lo = mathutils.Vector((float("inf"),) * 3)
    hi = mathutils.Vector((-float("inf"),) * 3)
    for c in o.bound_box:
        w = o.matrix_world @ mathutils.Vector(c)
        for i in range(3):
            if w[i] < lo[i]:
                lo[i] = w[i]
            if w[i] > hi[i]:
                hi[i] = w[i]
    return lo, hi


class DSU:
    def __init__(self, n):
        self.p = list(range(n))

    def find(self, x):
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.p[rb] = ra
            return True
        return False


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parse_args(argv)

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    bpy.ops.import_scene.fbx(filepath=args["input"])
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not objs:
        print("MODULES_JSON " + json.dumps({"error": "нет мешей"}, ensure_ascii=False))
        return

    boxes = []
    for o in objs:
        lo, hi = obj_box(o)
        boxes.append((lo, hi))

    # сортировка по X для ускорения отбора пар
    order = sorted(range(len(boxes)), key=lambda i: boxes[i][0].x)
    dsu = DSU(len(boxes))

    # размеры объектов — для адаптивного eps
    sizes = sorted(min(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z) for lo, hi in boxes)
    med_min = sizes[len(sizes) // 2] if sizes else 0.01
    eps = max(args["merge_eps"], med_min * 0.02)

    # группировка по X-диапазонам, затем проверка перекрытия по Y и Z
    groups = []
    cur = [order[0]]
    cur_max = boxes[order[0]][1].x
    for idx in order[1:]:
        lo, hi = boxes[idx]
        if lo.x > cur_max - eps:
            groups.append(cur)
            cur = [idx]
            cur_max = hi.x
        else:
            cur.append(idx)
            cur_max = max(cur_max, hi.x)
    groups.append(cur)

    merges = 0
    for g in groups:
        for ii in range(len(g)):
            for jj in range(ii + 1, len(g)):
                a, b = g[ii], g[jj]
                alo, ahi = boxes[a]
                blo, bhi = boxes[b]
                ox = min(ahi.x, bhi.x) - max(alo.x, blo.x)
                oy = min(ahi.y, bhi.y) - max(alo.y, blo.y)
                oz = min(ahi.z, bhi.z) - max(alo.z, blo.z)
                # перекрытие по всем трём осям > eps => одна и та же деталь конструкции
                if ox > eps and oy > eps and oz > eps:
                    if dsu.union(a, b):
                        merges += 1

    comps = {}
    for i in range(len(boxes)):
        r = dsu.find(i)
        comps.setdefault(r, []).append(i)

    # отсекаем одиночные мелкие объекты (фурнитура, ручки) в отдельную корзину
    mod_list = []
    for r, idxs in comps.items():
        lo_x = min(boxes[i][0].x for i in idxs)
        hi_x = max(boxes[i][1].x for i in idxs)
        lo_y = min(boxes[i][0].y for i in idxs)
        hi_y = max(boxes[i][1].y for i in idxs)
        lo_z = min(boxes[i][0].z for i in idxs)
        hi_z = max(boxes[i][1].z for i in idxs)
        mod_list.append({
            "objects": len(idxs),
            "x": [round(lo_x, 4), round(hi_x, 4)],
            "width": round(hi_x - lo_x, 4),
            "depth": round(hi_y - lo_y, 4),
            "height": round(hi_z - lo_z, 4),
            "names": [objs[i].name for i in idxs],
        })

    mod_list.sort(key=lambda m: m["x"][0])
    total_span = max((m["x"][1] for m in mod_list), default=1) - \
        min((m["x"][0] for m in mod_list), default=0)

    for n, m in enumerate(mod_list, 1):
        m["n"] = n
        m["pct"] = round(100.0 * m["width"] / total_span, 2) if total_span else 0

    print("MODULES_JSON " + json.dumps({
        "file": os.path.basename(args["input"]),
        "objects_total": len(objs),
        "merge_eps": round(eps, 5),
        "merges": merges,
        "modules_found": len(mod_list),
        "total_span_x": round(total_span, 4),
        "modules": mod_list,
    }, ensure_ascii=False))


main()