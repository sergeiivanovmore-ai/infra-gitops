import bpy
import math
import mathutils
import json
import os

# ============================================================
# КОНФИГУРАЦИЯ (измени под свою задачу)
# ============================================================
FBX_PATH = "/opt/data/workspace/dsh_model_split/input/Penaly.FBX"   # входной FBX
OUT_DIR = "/opt/data/workspace/dsh_model_split/veresk2/model"      # выходные FBX
N_PARTS = 6                                         # число итоговых моделей (по элементам мебели)
MAIN_AXIS = 'auto'                                  # 'X', 'Y', 'Z' или 'auto'
# Маппинг кластеров -> итоговые модели (настраивается под геометрию)
# Для шкафа: боковины, полки, центральные элементы раздельно
CLUSTER_TO_GROUP = {
    'element_1': [0],           # левый край
    'element_2': [1],           # левая внутренняя
    'element_3': [2],           # левая центральная
    'element_4': [3],           # правая центральная
    'element_5': [4],           # правая внутренняя
    'element_6': [5],           # правый край
}
# ============================================================

# Чистая сцена
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()

# Загрузка FBX
bpy.ops.import_scene.fbx(filepath=FBX_PATH)

mesh_objs = [o for o in bpy.context.scene.objects if o.type == 'MESH']
if not mesh_objs:
    print("ERROR: No mesh objects found!")
    exit(1)

# Определение главной оси
def get_main_axis(objs):
    min_all = {'X': float('inf'), 'Y': float('inf'), 'Z': float('inf')}
    max_all = {'X': -float('inf'), 'Y': -float('inf'), 'Z': -float('inf')}
    for obj in objs:
        corners = [obj.matrix_world @ mathutils.Vector(c) for c in obj.bound_box]
        for c in corners:
            for i, axis in enumerate(['X', 'Y', 'Z']):
                min_all[axis] = min(min_all[axis], c[i])
                max_all[axis] = max(max_all[axis], c[i])
    spans = {axis: max_all[axis] - min_all[axis] for axis in ['X', 'Y', 'Z']}
    return max(spans, key=spans.get)

if MAIN_AXIS == 'auto':
    MAIN_AXIS = get_main_axis(mesh_objs)
print(f"Main axis: {MAIN_AXIS}")

axis_idx = {'X': 0, 'Y': 1, 'Z': 2}[MAIN_AXIS]

# Считаем мировые границы по главной оси
obj_bounds = {}
for obj in mesh_objs:
    corners = [obj.matrix_world @ mathutils.Vector(c) for c in obj.bound_box]
    coords = [c[axis_idx] for c in corners]
    min_v, max_v = min(coords), max(coords)
    center_v = (min_v + max_v) / 2
    obj_bounds[obj] = {'min': min_v, 'max': max_v, 'center': center_v}

# Сортировка по центру на главной оси
mesh_objs.sort(key=lambda o: obj_bounds[o]['center'])

# Поиск зазоров между соседними объектами
gaps = []
for i in range(len(mesh_objs) - 1):
    gap = obj_bounds[mesh_objs[i+1]]['min'] - obj_bounds[mesh_objs[i]]['max']
    if gap > 0:
        gaps.append((gap, obj_bounds[mesh_objs[i]]['max'], obj_bounds[mesh_objs[i+1]]['min']))

# Debug: все зазоры
gaps.sort(reverse=True, key=lambda g: g[0])
print(f"All gaps (top 10):")
for i, (gap, left, right) in enumerate(gaps[:10]):
    print(f"  {i}: gap={gap:.4f}, left={left:.4f}, right={right:.4f}")

# Берём топ-(N_PARTS-1) зазоров = N_PARTS кластеров
n_splits = min(N_PARTS - 1, len(gaps))
split_pos = sorted([g[1] for g in gaps[:n_splits]])  # левая граница зазора
print(f"Split positions (left edge of gaps): {[f'{sp:.4f}' for sp in split_pos]}")

# Назначение кластеров
obj_cluster = {}
for obj in mesh_objs:
    obj_cluster[obj] = sum(1 for sp in split_pos if obj_bounds[obj]['center'] > sp)

# Группировка по кластерам
clusters = {}
for obj in mesh_objs:
    clusters.setdefault(obj_cluster[obj], []).append(obj)

# Debug
cluster_ids = sorted(clusters.keys())
print(f"Detected {len(cluster_ids)} clusters: {cluster_ids}")
for cid in cluster_ids:
    print(f"  Cluster {cid}: {len(clusters[cid])} objects")

# Маппинг кластеров -> итоговые модели
if len(cluster_ids) >= len(CLUSTER_TO_GROUP):
    groups = {}
    for group_name, cluster_list in CLUSTER_TO_GROUP.items():
        objs = []
        for cid in cluster_list:
            objs.extend(clusters.get(cid, []))
        if objs:
            groups[group_name] = objs
else:
    # Fallback: равномерное распределение
    all_objs = sorted(mesh_objs, key=lambda o: obj_bounds[o]['center'])
    n = len(all_objs)
    groups = {}
    group_names = list(CLUSTER_TO_GROUP.keys())
    for i, name in enumerate(group_names):
        start = i * n // len(group_names)
        end = (i + 1) * n // len(group_names)
        groups[name] = all_objs[start:end]

groups = {k: v for k, v in groups.items() if v}
print(f"Final groups: {[(k, len(v)) for k, v in groups.items()]}")

os.makedirs(OUT_DIR, exist_ok=True)

# Экспорт каждой группы в отдельный FBX
for name, objs in groups.items():
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]

    fbx_path = os.path.join(OUT_DIR, f"{name}.fbx")
    bpy.ops.export_scene.fbx(filepath=fbx_path,
        use_selection=True, bake_anim=False,
        bake_anim_use_all_actions=False, bake_anim_use_nla_strips=False,
        bake_anim_force_startend_keying=False)
    print(f"Exported {fbx_path} ({len(objs)} objects)")

# Сохраняем маппинг для рендера
with open(os.path.join(OUT_DIR, "groups.json"), "w") as f:
    json.dump({k: [o.name for o in v] for k, v in groups.items()}, f)

print("Analysis and split complete!")