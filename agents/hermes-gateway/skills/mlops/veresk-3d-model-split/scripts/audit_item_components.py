#!/usr/bin/env python3
"""Аудит и ремонт разбиения по items_index.json (Blender).

Находит и чинит два класса ошибок:
  * недо-сегментация — узкий «осколок», перекрывающийся с широким соседом
  * пере-сегментация — в одном предмете несколько предметов (зазор по X >= GAP)

Метрика: связные компоненты по пересечению 3D-AABB. X-зазоры внутри предметов
бесполезны (панели одного шкафа перекрываются), связность в 3D — надёжна.

ПОРЯДОК: сначала РАЗДЕЛЕНИЕ, потом СКОЛЕЙКА. Иначе кусок, отрезанный от 206,
не приклеится к 205.

Запуск:
  blender --background --python scripts/audit_item_components.py -- \
    --fbx model.fbx --index items_index.json \
    [--out items_index_fixed.json] [--apply] [--gap 0.15] [--sliver 0.6]

Без --apply только печатает разбор (ничего не пишет).
С --apply пишет исправленный индекс и печатает AUDIT_OK.
"""
import bpy
import json
import sys
from collections import defaultdict
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def arg(flag, default=None):
    return argv[argv.index(flag) + 1] if flag in argv else default


FBX = arg("--fbx")
INDEX = arg("--index")
OUT = arg("--out")
APPLY = "--apply" in argv
GAP = float(arg("--gap", "0.15"))
SLIVER = float(arg("--sliver", "0.6"))
HAIR = float(arg("--hair", "0.06"))
TOL = 0.02          # перекрытие не должно быть чистым касанием
EPS = 1e-3          # допуск при назначении объектов предмету

if not FBX or not INDEX:
    raise SystemExit("нужны --fbx и --index")

bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()
bpy.ops.import_scene.fbx(filepath=FBX)
bpy.context.view_layer.update()

objs = {}
for o in bpy.context.scene.objects:
    if o.type != 'MESH' or not len(o.data.vertices):
        continue
    cs = [o.matrix_world @ Vector(c) for c in o.bound_box]
    objs[o.name] = {
        "x0": min(c.x for c in cs), "x1": max(c.x for c in cs),
        "y0": min(c.y for c in cs), "y1": max(c.y for c in cs),
        "z0": min(c.z for c in cs), "z1": max(c.z for c in cs),
    }
names = sorted(objs)
N = len(names)
print("AUDIT_MESHES %d" % N, flush=True)


def xbb(mem):
    if not mem:
        return (0.0, 0.0)
    return (min(objs[m]["x0"] for m in mem), max(objs[m]["x1"] for m in mem))


def center(n):
    return (objs[n]["x0"] + objs[n]["x1"]) / 2.0


# ---------- компоненты по 3D-AABB ----------
parent = list(range(N))


def find(x):
    while parent[x] != x:
        parent[x] = parent[parent[x]]
        x = parent[x]
    return x


for i in range(N):
    a = objs[names[i]]
    for j in range(i + 1, N):
        b = objs[names[j]]
        ox = min(a["x1"], b["x1"]) - max(a["x0"], b["x0"])
        if ox <= 0:
            continue
        oy = min(a["y1"], b["y1"]) - max(a["y0"], b["y0"])
        if oy <= 0:
            continue
        oz = min(a["z1"], b["z1"]) - max(a["z0"], b["z0"])
        if oz <= 0:
            continue
        if ox < TOL and oy < TOL and oz < TOL:
            continue
        ra, rb = find(i), find(j)
        if ra != rb:
            parent[ra] = rb

comp_of = {names[i]: find(i) for i in range(N)}
print("AUDIT_COMPONENTS %d" % len(set(comp_of.values())), flush=True)

# ---------- исходные предметы ----------
idx = json.load(open(INDEX))
items = []
for it in idx["items"]:
    mem = [n for n in names
           if center(n) >= it["c0"] - EPS and center(n) <= it["c1"] + EPS]
    items.append({"n": it["n"], "mem": mem, "src": it["n"]})
print("AUDIT_ITEMS %d" % len(items), flush=True)

# ---------- ШАГ 1: РАЗДЕЛЕНИЕ ----------
split_log = []
pieces = []
for it in items:
    grp = defaultdict(list)
    for m in it["mem"]:
        grp[comp_of[m]].append(m)
    blocks = sorted(grp.values(), key=lambda g: min(objs[m]["x0"] for m in g))
    out, cur, cur_x1 = [], [], None
    for blk in blocks:
        bx0, bx1 = xbb(blk)
        if cur and bx0 < cur_x1 - 1e-9:      # перекрытие по X — тот же предмет
            cur += blk
            cur_x1 = max(cur_x1, bx1)
        else:
            if cur:
                out.append(cur)
            cur, cur_x1 = list(blk), bx1
    if cur:
        out.append(cur)
    if len(out) > 1:
        split_log.append((it["n"], len(out), [len(x) for x in out]))
    for piece in out:
        pieces.append({"mem": piece, "src": it["n"]})

print("AUDIT_SPLIT %d" % len(split_log), flush=True)
for n, k, sizes in split_log:
    print("   SPLIT n=%d -> %d (objs=%s)" % (n, k, sizes), flush=True)

# ---------- ШАГ 2: СКОЛЕЙКА осколков (двусторонняя) ----------
for p in pieces:
    p["x0"], p["x1"] = xbb(p["mem"])
    p["w"] = p["x1"] - p["x0"]
pieces.sort(key=lambda p: p["x0"])

merged = defaultdict(list)
alive = list(range(len(pieces)))
changed = True
while changed:
    changed = False
    for pos in range(len(alive)):
        me = alive[pos]
        pm = pieces[me]
        if pm["w"] >= SLIVER:
            continue
        tgt = None
        cands = []
        if pos > 0:
            cands.append(alive[pos - 1])
        if pos + 1 < len(alive):
            cands.append(alive[pos + 1])
        for nb in cands:
            pn = pieces[nb]
            if (pm["x1"] > pn["x0"] + 1e-9 and pn["x1"] > pm["x0"] + 1e-9
                    and pn["w"] > pm["w"]):
                tgt = nb
                break
        if tgt is None:
            continue
        pieces[tgt]["mem"] += pm["mem"]
        pieces[tgt]["x0"], pieces[tgt]["x1"] = xbb(pieces[tgt]["mem"])
        pieces[tgt]["w"] = pieces[tgt]["x1"] - pieces[tgt]["x0"]
        merged[pieces[tgt]["src"]].append(pm["src"])
        alive.remove(me)
        changed = True
        break

# ---------- ШАГ 3: ультратонкие планки -> к ближайшему ----------
alive = [i for i in alive if pieces[i]["mem"]]
alive.sort(key=lambda i: pieces[i]["x0"])
hair = [i for i in alive if pieces[i]["w"] < HAIR]
for h in hair:
    ph = pieces[h]
    cx = (ph["x0"] + ph["x1"]) / 2.0
    best, bestd = None, None
    for j in alive:
        if j == h:
            continue
        pj = pieces[j]
        dd = abs((pj["x0"] + pj["x1"]) / 2.0 - cx)
        if bestd is None or dd < bestd:
            best, bestd = j, dd
    if best is None:
        continue
    pieces[best]["mem"] += ph["mem"]
    pieces[best]["x0"], pieces[best]["x1"] = xbb(pieces[best]["mem"])
    pieces[best]["w"] = pieces[best]["x1"] - pieces[best]["x0"]
    merged[pieces[best]["src"]].append(ph["src"])
    alive.remove(h)

print("AUDIT_MERGED %d" % sum(len(v) for v in merged.values()), flush=True)
for t in sorted(merged):
    print("   MERGE into n=%d <- %s" % (t, sorted(merged[t])), flush=True)

final = [pieces[i] for i in alive]
final.sort(key=lambda p: p["x0"])
print("AUDIT_TOTAL %d -> %d" % (len(items), len(final)), flush=True)

# ---------- инварианты ----------
uniq = len({m for f in final for m in f["mem"]})
if uniq != N:
    raise SystemExit("ПОТЕРЯ ОБЪЕКТОВ: %d из %d" % (uniq, N))
tiny = [f for f in final if len(f["mem"]) <= 2 or (f["x1"] - f["x0"]) < 0.35]
print("AUDIT_TINY_LEFT %d" % len(tiny), flush=True)

# ---------- запись индекса ----------
out_items = []
for k, f in enumerate(final, 1):
    mem = sorted(set(f["mem"]))
    x0, x1 = xbb(mem)
    ctr = [center(q) for q in mem]
    c0, c1 = min(ctr), max(ctr)
    if c1 - c0 < 1e-9:                      # однообъектный предмет
        c0, c1 = x0 + 1e-6, x1 - 1e-6
        if c1 <= c0:
            c0, c1 = x0 - 1e-4, x1 + 1e-4
    out_items.append({
        "n": k, "src": f["src"], "c0": round(c0, 4), "c1": round(c1, 4),
        "x0": round(x0, 4), "x1": round(x1, 4),
        "width": round(x1 - x0, 4),
        "height": round(max(objs[q]["z1"] for q in mem)
                        - min(objs[q]["z0"] for q in mem), 4),
        "objects": len(mem),
    })

# проверка: пересчёт по c0/c1 должен давать тот же состав
mismatch = 0
for it in out_items:
    sel = {q for q in names if it["c0"] - EPS <= center(q) <= it["c1"] + EPS}
    if len(sel) != it["objects"]:
        mismatch += 1
print("AUDIT_C0C1_MISMATCH %d" % mismatch, flush=True)

if APPLY:
    if not OUT:
        raise SystemExit("с --apply нужен --out")
    doc = {"model": idx.get("model"), "axis": idx.get("axis", "X"),
           "method": "component-repair", "count": len(out_items),
           "meshes": N, "items": out_items}
    with open(OUT, "w") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=1)
    print("AUDIT_WROTE %s" % OUT, flush=True)

print("AUDIT_OK", flush=True)