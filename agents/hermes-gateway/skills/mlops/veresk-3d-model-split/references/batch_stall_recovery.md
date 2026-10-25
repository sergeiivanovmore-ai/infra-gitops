# Восстановление после зависшего/упавшего батча

Сценарий: много предметов (100+), батч идёт через `batch_split_render.py`,
cron-сторож следит за прогрессом. Батч встал — что делать.

## 0. Стоп-сигнал: сторож повторяет одно и то же

Сторож с `schedule: "*/3 * * * *"`, `repeat: forever`, `no_agent: true`,
`deliver: origin` шлёт **каждые 3 минуты**. Если работа упала и её не чинили —
это спам по 10+ часов.

**Важно: повторяющееся сообщение сторожа — не баг сторожа.** Сторож честно
докладывает о реальной проблеме («Процесс завершился, а работа не закончена
(88/211)»). Баг — в том, что застрявший батч не починили.

```bash
# сначала — снять спам, потом чинить (иначе сообщения сыплются поверх отчёта)
# cronjob(action='pause', job_id=...)
```

Возобновлять сторож (`resume`) — **только после** того, как батч реально
идёт и `last_change_ts` в state-файле обновляется. Проверяй это, а не
`last_status` (он `ok` даже когда работа стоит).

## 1. ГДЕ умер батч — читать лог, а не гадать

```bash
D=/opt/data/workspace/dsh_model_split/<Model>
tail -5 /tmp/vil/batch_<model>.log             # хвост лога
grep -E "^ITEM (86|87|88|89|90)/" "$LOG"       # окно вокруг места обрыва
stat -c '%y' "$LOG"                            # когда умер
ls "$D/parts" | wc -l                          # сколько реально готово
```

Предмет, на котором лог обрывается без строки `ITEM ...` — и есть виновник.

## 2. НИКОГДА не перезапускай batch-скрипт целиком

```bash
head -20 "$D/scripts/run_batch_*.sh"
```

Многие батч-скрипты начинаются с

```bash
rm -rf "$D/parts" "$D/renders"     # ← снесёт весь готовый результат
```

Перезапуск такого скрипта уничтожает 88 готовых предметов и начинает заново.
**Проверяй первые строки скрипта ДО запуска.**

## 3. Продолжение с места падения — `resume`

`batch_split_render.py` уже умеет резюмировать:

```python
RESUME = C.get("resume", False)
# готовым считается файл, если он существует и НЕПУСТОЙ
if RESUME and os.path.exists(fbx_p) and os.path.getsize(fbx_p) > 0 \
        and (not DO_RENDER or (os.path.exists(png_p) and os.path.getsize(png_p) > 0)):
    ...print("ITEM %d/%d n=%d SKIP (уже готов)")
```

Запуск без `rm -rf`:

```bash
"$B" --background --python .../batch_split_render.py -- \
  "{\"fbx\":\"$D/input/Dario.fbx\",\"index\":\"$D/items_index.json\",
    \"parts_dir\":\"$D/parts\",\"renders_dir\":\"$D/renders\",
    \"report\":\"$D/split_report.json\",\"res\":1024,\"samples\":64,
    \"resume\":true}"
```

`resume` по умолчанию **False** — без него всё перерендерится заново.
Точечный прогон: `"only":[89,90]`.

## 4. Ловушка приёма ключа

Индекс хранит номера как **числа**. Скрипт читает
`{i["n"]: i for i in idx["items"]}[C["item"]]` — если передать `"item":"89"`
строкой, получишь `KeyError: '89'`. Приводи к int на обеих сторонах:

```python
items = {int(i["n"]): i for i in idx["items"]}
it = items[int(C["item"])]
```

## 5. Google Drive: ID папок протухают

ID, зашитый в скриптах (`ROOT_FOLDER_ID`), может вести в **пустую** папку —
загрузка пройдёт «успешно», файлы уйдут в никуда.

```python
def children(fid):
    q = urllib.parse.quote(f"'{fid}' in parents and trashed=false")
    ...GET f"https://www.googleapis.com/drive/v3/files?q={q}&fields=files(id,name,mimeType,size)"
children("root")            # верхний уровень
search("3dmodels")          # по имени, если ID неизвестен
```

Конвенцию соседей смотри **до** создания своих папок: у соседних моделей
уже есть `<Model>/models/` + `<Model>/renders/` — повторяй её.

## 6. Дубликаты в целевой папке

Перед загрузкой — посмотри, что уже лежит:

```python
fs = children(target_id)      # 8 файлов вместо 4 = следы прошлой сессии
```

Имена вида `1.fbx`/`1_iso.png` совпадут у дублей, а `id` — разные.
Оставь актуальную версию, старые отправь в корзину (**обратимо**):
`DELETE https://www.googleapis.com/drive/v3/files/<id>` → HTTP 204.

Разный md5 при одинаковом размере FBX — это НЕ разная геометрия: FBX
внутри хранит время создания и уникальные ID. Сравнивай рендеры глазами,
прежде чем считать файлы дублями.

## 7. Проверка загрузки — только round-trip

```python
url = f"https://www.googleapis.com/drive/v3/files/{fid}?alt=media"
data = urllib.request.urlopen(urllib.request.Request(url, headers=auth)).read()
assert hashlib.md5(data).hexdigest() == md5(local)
```

Multipart: **ровно одна** пустая строка после
`Content-Type: application/octet-stream`, иначе файл начнётся с `\r\n`.