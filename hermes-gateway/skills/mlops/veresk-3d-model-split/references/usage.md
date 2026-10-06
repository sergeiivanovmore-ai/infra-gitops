# Использование пайплайна

> ⚠️ Этот файл описывает **старый** пайплайн с хардкод-конфигом.
> Актуальный интерактивный сценарий — в `interactive_flow.md`, он же описан в `SKILL.md`.
> Скрипты `analyze_and_split.py`, `render_isometric.py`, `upload_to_gdrive.py` оставлены
> для обратной совместимости и требуют ручной правки путей в шапке файла.

## Актуальный пайплайн (кратко)

```bash
S=/opt/data/skills/mlops/veresk-3d-model-split/scripts

# 1. Список FBX в папке Drive + прогноз числа частей по каждому файлу
python3 $S/predict_batch.py --folder "https://drive.google.com/drive/folders/ID" --parts 4

# 2. Обработка одного файла: скачать → разделить выбранные части → отрендерить → загрузить
python3 $S/process_file.py \
    --folder "https://drive.google.com/drive/folders/ID" \
    --file-id FILE_ID --file-name "Шкаф.fbx" \
    --parts 4 --select "1,3"
```

Результат: `<папка>/Шкаф/models/{1,3}.fbx` и `<папка>/Шкаф/renders/{1,3}_iso.png`

## Низкоуровневые вызовы

```bash
# Прогноз по одному локальному FBX
blender --background --python $S/predict_parts.py -- \
    --input model.fbx --parts 4 --axis auto

# Разбиение с выбором конкретных частей
blender --background --python $S/split_selected.py -- \
    --input model.fbx --out ./models --parts 4 --select 2,4

# Рендер всех FBX в папке
blender --background --python $S/render_parts.py -- \
    --models-dir ./models --out-dir ./renders --samples 128 --res 1024
```

## Полезные комбинации

| Задача | Как |
|--------|-----|
| Быстрый тест без долгого рендера | `--samples 16 --res 512` |
| Объединить кластеры в одну модель | `--mapping "1:0,2:1+2,3:3,4:4+5"` |
| Жёстче искать зазоры | `--min-gap-ratio 0.01` |
| Только посмотреть, без загрузки | `--skip-upload` (в `process_file.py`) |
| Пересчитать прогноз без кэша | `--force` (в `predict_batch.py`) |

## Структура результата

```
<workdir>/<Имя_файла>/
├── input/<Имя_файла>.fbx
├── models/{1..N}.fbx + groups.json + split_manifest.json
└── renders/{1..N}_iso.png
```

На Google Drive:
```
<исходная папка>/<Имя_файла>/models/*.fbx
<исходная папка>/<Имя_файла>/renders/*.png
```

---

## Старый пайплайн (legacy) — для справки

Использовался для разовой обработки с фиксированным числом частей и маппингом в коде.

```python
# analyze_and_split.py — правки в шапке файла
FBX_PATH = "/path/to/model.fbx"
OUT_DIR  = "/path/to/parts"
N_PARTS  = 4
MAIN_AXIS = 'auto'
CLUSTER_TO_GROUP = {'element_1': [0], 'element_2': [1], ...}
```

```python
# render_isometric.py
PARTS_DIR = "/path/to/parts"
RENDER_DIR = "/path/to/renders"
RESOLUTION = (1024, 1024)
SAMPLES = 128
CAMERA_ANGLE_DEG = (35.264, -45)
```

```python
# upload_to_gdrive.py
TOKEN_PATH = "/opt/data/google_token.json"
FOLDER_ID  = "1AGz0myzDGNX0oCq_fQJbOg2aboarOs35"
```

> ⚠️ В legacy-скриптах камера рендера смотрит в начало координат, а не в центр модели.
> Новый `render_parts.py` это исправляет (target = центр bbox) — используй его.