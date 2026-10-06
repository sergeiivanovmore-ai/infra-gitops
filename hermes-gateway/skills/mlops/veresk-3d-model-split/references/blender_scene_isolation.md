# Blender — изоляция сцены для каждого экспорта/рендера

## Проблема
Если загрузить все модели в одну сцену и экспортировать/рендерить по очереди — объекты накапливаются, материалы смешиваются, рендеры получаются с чужими объектами.

## Решение: полная очистка сцены перед каждой операцией

## Паттерн: чистая сцена для каждой модели

```python
def process_model(model_name, fbx_path, output_path):
    # 1. Полная очистка
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()
    
    # 2. Загрузка только нужного FBX
    bpy.ops.import_scene.fbx(filepath=fbx_path)
    obj = bpy.context.selected_objects[0]
    obj.name = model_name
    
    # 3. Материал (если нужен единый)
    mat = bpy.data.materials.new('Mat')
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes['Principled BSDF']
    bsdf.inputs['Base Color'].default_value = (0.8, 0.8, 0.8, 1)
    bsdf.inputs['Roughness'].default_value = 0.3
    if obj.data.materials:
        obj.data.materials[0] = mat
    else:
        obj.data.materials.append(mat)
    
    # 4. Экспорт или рендер
    if output_path.endswith('.fbx'):
        bpy.ops.object.select_all(action='DESELECT')
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.export_scene.fbx(filepath=output_path, use_selection=True)
    else:
        render_iso(obj, output_path)  # твоя функция рендера
    
    print(f"Done: {output_path}")

# Использование в цикле
for name in ['model_1', 'model_2', 'model_3']:
    fbx = f"/path/{name}.fbx"
    out = f"/path/{name}.fbx"
    process_model(name, fbx, out)
```

## Почему это важно
- **Нет дублей** — старые объекты не остаются в сцене
- **Чистые материалы** — каждый рендер с своим материалом
- **Предсказуемость** — каждая итерация независима
- **Память** — Blender не накапливает меши прошлых итераций

## Применение в наших скриптах

### analyze_and_split.py
```python
# Экспорт каждой группы в изолированной сцене
for name, objs in groups.items():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()  # чистая сцена
    
    # Переимпорт исходного FBX или копирование объектов
    # (мы переимпортируем — проще и надёжнее)
    bpy.ops.import_scene.fbx(filepath=FBX_PATH)
    # фильтруем нужные объекты...
    bpy.ops.export_scene.fbx(filepath=fbx_path, use_selection=True)
```

### render_isometric.py
```python
for name in groups.keys():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()
    
    bpy.ops.import_scene.fbx(filepath=fbx_path)
    obj = bpy.context.selected_objects[0]
    obj.name = name
    
    render_iso(obj, png_path)
```

## Альтернатива: копирование объектов (без реимпорта)
Если исходная сцена уже загружена и не хочется реимпортировать:

```python
# Копируем только нужные объекты в новую сцену
bpy.ops.object.select_all(action='DESELECT')
for obj in objects_to_export:
    obj.select_set(True)
bpy.context.view_layer.objects.active = objects_to_export[0]

# Duplicate
bpy.ops.object.duplicate_move()
duplicated = bpy.context.selected_objects

# Новая сцена
new_scene = bpy.data.scenes.new(name="TempRender")
bpy.context.window.scene = new_scene

# Link duplicated objects to new scene
for obj in duplicated:
    new_scene.collection.objects.link(obj)
    bpy.data.scenes[0].collection.objects.unlink(obj)  # unlink from old

# ... рендер/экспорт ...

# Удаляем временную сцену
bpy.data.scenes.remove(new_scene)
```

## Резюме
| Подход | Плюсы | Минусы |
|--------|-------|--------|
| **Реимпорт FBX** | Просто, гарантированно чисто | Медленнее на больших файлах |
| **Duplicate + новая сцена** | Быстрее, сохраняет модификаторы | Сложнее, нужно чистить сцены |

**Рекомендация**: для наших задач (FBX до 80 MB) — **реимпорт**. Проще, надежнее, время не критично.