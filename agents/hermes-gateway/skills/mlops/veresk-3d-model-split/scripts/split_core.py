"""
Общая логика разделения 3D-модели по естественным зазорам вдоль главной оси.
Используется из Blender (bpy), НЕ запускается как самостоятельный скрипт.

Функции:
  detect_main_axis(objs)   -> (axis, spans)
  world_bounds(obj, idx)   -> (min, max)
  analyze(objs, n_parts, axis='auto', min_gap_ratio=0.0) -> dict
  resolve_mapping(clusters, mapping) -> {group_name: [objects]}
"""

import mathutils

AXES = ("X", "Y", "Z")


def detect_main_axis(objs):
    """Ось с максимальным суммарным span по всем объектам."""
    lo = {a: float("inf") for a in AXES}
    hi = {a: -float("inf") for a in AXES}
    for obj in objs:
        for c in obj.bound_box:
            w = obj.matrix_world @ mathutils.Vector(c)
            for i, a in enumerate(AXES):
                if w[i] < lo[a]:
                    lo[a] = w[i]
                if w[i] > hi[a]:
                    hi[a] = w[i]
    spans = {a: (hi[a] - lo[a]) for a in AXES}
    return max(spans, key=spans.get), spans


def world_bounds(obj, axis_idx):
    """Мировые границы объекта по заданной оси -> (min, max)."""
    coords = [(obj.matrix_world @ mathutils.Vector(c))[axis_idx] for c in obj.bound_box]
    return min(coords), max(coords)


def analyze(objs, n_parts="auto", axis="auto", min_gap_ratio=0.0):
    """
    Разбор модели: главная ось, зазоры, позиции резов, кластеры.

    n_parts:
        "auto" (по умолчанию) — НЕ задавать число частей заранее: берём ВСЕ
            естественные зазоры и получаем N = len(зазоры) + 1. Это то самое
            количество моделей, которое получится при автоматическом
            сегментировании по самой длинной оси.
        int (например 4) — взять топ-(n_parts-1) самых широких зазоров.

    min_gap_ratio — порог зазора как доля от общего span.
                    0.0 = любой положительный зазор (по умолчанию).

    Возвращает dict:
      axis, axis_idx, spans, objects, gaps_total, gaps_usable,
      splits[], clusters[], planned_parts, parts_mode, not_enough_gaps
    """
    detected_axis, spans = detect_main_axis(objs)
    use_axis = axis if (axis and axis != "auto") else detected_axis
    axis_idx = AXES.index(use_axis)
    total_span = spans[detected_axis] or 1.0

    bounds = {}
    for o in objs:
        mn, mx = world_bounds(o, axis_idx)
        bounds[o] = {"min": mn, "max": mx, "center": (mn + mx) / 2.0}

    ordered = sorted(objs, key=lambda o: bounds[o]["center"])

    gaps = []
    for i in range(len(ordered) - 1):
        g = bounds[ordered[i + 1]]["min"] - bounds[ordered[i]]["max"]
        if g > 0:
            gaps.append(
                {
                    "gap": g,
                    "left": bounds[ordered[i]]["max"],
                    "right": bounds[ordered[i + 1]]["min"],
                    "left_obj": ordered[i].name,
                    "right_obj": ordered[i + 1].name,
                }
            )

    gaps.sort(key=lambda g: g["gap"], reverse=True)
    threshold = total_span * min_gap_ratio
    usable = [g for g in gaps if g["gap"] >= threshold] if threshold > 0 else gaps

    # --- выбор числа частей ---
    if n_parts is None or (isinstance(n_parts, str) and n_parts.strip().lower() in ("auto", "")):
        # Автоматическая сегментация: каждый естественный зазор = разрез
        n_splits = len(usable)
        parts_mode = "auto"
    else:
        n_splits = min(max(int(n_parts) - 1, 0), len(usable))
        parts_mode = "fixed"

    split_pos = sorted(g["left"] for g in usable[:n_splits])
    not_enough = parts_mode == "fixed" and n_splits < max(int(n_parts) - 1, 0)

    # Сколько частей получится при отбрасывании совсем мелких зазоров (>1% span)
    robust_splits = len([g for g in gaps if g["gap"] >= total_span * 0.01])

    clusters_map = {}
    for o in ordered:
        cid = sum(1 for sp in split_pos if bounds[o]["center"] > sp)
        clusters_map.setdefault(cid, []).append(o)

    clusters = []
    for cid in sorted(clusters_map.keys()):
        objs_c = clusters_map[cid]
        mins = [bounds[o]["min"] for o in objs_c]
        maxs = [bounds[o]["max"] for o in objs_c]
        clusters.append(
            {
                "idx": cid,
                "count": len(objs_c),
                "min": min(mins),
                "max": max(maxs),
                "names": [o.name for o in objs_c],
            }
        )

    return {
        "axis": use_axis,
        "axis_idx": axis_idx,
        "detected_axis": detected_axis,
        "spans": spans,
        "total_span": total_span,
        "objects": len(objs),
        "gaps": gaps[:20],
        "gaps_total": len(gaps),
        "gaps_usable": len(usable),
        "gaps_robust": robust_splits,
        "planned_parts_robust": robust_splits + 1,
        "splits": split_pos,
        "clusters": clusters,
        "planned_parts": len(clusters),
        "parts_mode": parts_mode,
        "not_enough_gaps": not_enough,
        "min_gap_ratio": min_gap_ratio,
    }


def resolve_mapping(clusters, mapping=None):
    """
    Превратить кластеры в итоговые группы моделей.

    mapping=None или {} -> каждая модель = один кластер ('1', '2', ... слева направо).
    mapping              -> {group_name: [cluster_idx, ...]} как в исходном скилле.
    """
    by_idx = {c["idx"]: c for c in clusters}
    groups = {}

    if not mapping:
        for c in clusters:
            groups[str(c["idx"] + 1)] = c["names"]
        return groups

    for name, cid_list in mapping.items():
        names = []
        for cid in cid_list:
            if cid in by_idx:
                names.extend(by_idx[cid]["names"])
        if names:
            groups[str(name)] = names
    return groups