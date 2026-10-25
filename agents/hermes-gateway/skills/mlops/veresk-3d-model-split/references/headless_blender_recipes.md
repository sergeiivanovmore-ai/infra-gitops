# Headless Blender: рабочие рецепты

Проверено на Дарио (2375 объектов, 674 actions) и Лорэна Премиум (1082 объекта,
890 actions). Каждый рецепт — с ошибкой, которая стоила итерации.

## 1. Передача путей в скрипт Blender

**Не использовать разделитель `--`:**

```bash
# НЕ РАБОТАЕТ — харнесс переставляет аргументы, Blender читает флаги как файлы
blender --background --python script.py -- input.fbx out.json
# RuntimeError: Couldn't open file '--background'
```

**Работает — переменные окружения:**

```bash
export LOR_FBX=/abs/path/model.fbx LOR_OUT=/abs/path/out.json
blender --background --factory-startup --python /tmp/script.py
```

```python
FBX = os.environ["LOR_FBX"]
OUT = os.environ["LOR_OUT"]
```

`--factory-startup` полезен: без него подгружаются пользовательские аддоны и
настройки, которые ломают headless-прогон.

## 2. Рендер: только Cycles CPU

EEVEE в headless требует GPU-контекст:

```
Couldn't open libEGL.so.1: libEGL.so.1: cannot open shared object file
```

Результат — пустой PNG без ошибки в stdout. Всегда:

```python
sc.render.engine = 'CYCLES'
sc.cycles.device = 'CPU'
sc.cycles.samples = 64          # 24-32 для контрольных, 64 для финальных
sc.cycles.use_denoising = True
sc.cycles.max_bounces = 3       # 2 хватает для панелей
```

Ориентиры времени (CPU, 1024×1024): панель 7-8 сек при 24 spp, шкаф ~25 сек при
64 spp. 42 предмета ≈ 6 мин при 64 spp.

## 3. Камера: фронтальный вид

Камера по умолчанию смотрит вдоль **-Z**. Чтобы смотреть вдоль **-Y** (фронт)
сверху вниз — поворот **-90°** по X:

```python
cam.location = (cx, gy1 + 40, cz)
cam.rotation_euler = (math.radians(-90), 0, 0)   # -90, НЕ +90
```

`+90` разворачивает камеру на 180° — кадр выходит однотонным (виден только фон).
Это самая дорогая ошибка в этой группе: рендер отрабатывает за секунды, выглядит
безошибочно, и без взгляда на картинку не диагностируется.

Изометрия — перспектива + `TRACK_TO`:

```python
cam_d.type = 'PERSP'; cam_d.lens = 42
d = size * 2.2                     # size = max габарит bbox предмета
cam.location = (ctr.x + d*0.62, ctr.y - d*1.05, ctr.z + d*0.55)
con = cam.constraints.new('TRACK_TO'); con.target = tgt
con.track_axis = 'TRACK_NEGATIVE_Z'; con.up_axis = 'UP_Y'
```

Дистанция считается от bbox **предмета**, а не фиксированная: у Дарьянки предметы
шириной от 0.5 до 2.2, фиксированная камера давала заполнение 25 % у мелких.

## 4. Флаги анимации: только экспорт

`bake_anim` / `bake_anim_use_all_actions` / `bake_anim_use_nla_strips` —
параметры **`export_scene.fbx`**. На импорте их нет:

```
TypeError: Converting py args to operator properties: keyword "bake_anim" unrecognized
```

Почему важно: сцена Дарио содержала **674 actions**, Лорэна Премиум — **890**.
FBX-экспорт каждого объекта прогонял все экшены сцены: экспорт 176 объектов
занимал 779 сек. С `bake_anim=False, bake_anim_use_all_actions=False,
bake_anim_use_nla_strips=False` — **0.38 сек**.

```python
EXPORT_KW = dict(
    bake_anim=False, bake_anim_use_all_actions=False,
    bake_anim_use_nla_strips=False,
    apply_scale_options='FBX_SCALE_UNITS',
    object_types={'MESH'}, use_mesh_modifiers=True,
)
bpy.ops.export_scene.fbx(filepath=out, use_selection=True, **EXPORT_KW)
```

## 5. Сортировка: объект Blender не сравнивается

```
TypeError: '<' not supported between instances of 'Object' and 'Object'
```

Сортировать по числовому ключу, объект — payload:

```python
iv = sorted(((info[o]["x0"], info[o]["x1"], i, o) for i, o in enumerate(meshes)),
            key=lambda t: (t[0], t[1]))
for a, b, _i, o in iv:
    ...
```

## 6. Bounds: считать все три оси

```python
gx0 = min(v[0] for v in info.values()); gx1 = max(v[1] for v in info.values())
gz0 = ...; gz1 = ...
gy1 = max(info[o]["yc"] for o in meshes) + 1.0     # нужен для позиции камеры
```

Если камера ставится по оси, чей bound не посчитан, — `NameError` в самом конце
скрипта, после всех тяжёлых операций.

## 7. Порядок в батч-прогоне

```python
for each item:
    bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete()
    for act in list(bpy.data.actions): bpy.data.actions.remove(act)   # убрать экшены
    bpy.ops.import_scene.fbx(filepath=FBX)
    by_name = {o.name: o for o in bpy.data.objects}
    present = [by_name[n] for n in item_members if n in by_name]
    bpy.ops.object.select_all(action='DESELECT')
    for o in present: o.select_set(True)
    ... экспорт use_selection=True ...
    ... рендер ...
```

`select_set` вместо `hide_render`: объекты вне выборки не попадают в FBX при
`use_selection=True`, но остаются в сцене — это безопасно и быстрее удалений.

Удаление экшенов в каждой итерации не обязательно, но убирает рост памяти при
длинных прогонах на анимированных сценах.