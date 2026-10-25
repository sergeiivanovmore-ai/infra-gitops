# Yandex Disk API — получение свежей ссылки для скачивания

## Проблема
Прямые ссылки на файлы Яндекс.Диска (`downloader.disk.yandex.ru/...`) живут недолго (часы/дни). При попытке скачивания по старой ссылке: 403 Forbidden, 404 Not Found, или таймаут.

## Решение: используй официальное API

### 1. Получи public_key из публичной ссылки
```
https://disk.yandex.ru/d/2fJ1ubFFphvc-g
```
→ `public_key = "https://disk.yandex.ru/d/2fJ1ubFFphvc-g"`

### 2. Запроси метаданные папки/файла
```python
import urllib.request
import urllib.parse
import json

public_key = "https://disk.yandex.ru/d/2fJ1ubFFphvc-g"
api_url = f"https://cloud-api.yandex.net/v1/disk/public/resources?public_key={urllib.parse.quote(public_key)}&limit=100"

req = urllib.request.Request(api_url, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req, timeout=30) as r:
    data = json.load(r)

# data['_embedded']['items'] — список файлов
for item in data['_embedded']['items']:
    if item['name'] == 'Вилена.fbx':
        download_url = item['file']  # свежая ссылка
        break
```

### 3. Скачай по свежей ссылке
```python
import shutil
req = urllib.request.Request(download_url, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req, timeout=300) as response, open("Вилена.fbx", "wb") as f:
    shutil.copyfileobj(response, f)
```

## Полный пример
```python
import urllib.request, urllib.parse, json, shutil

def download_from_yadisk(public_key, filename, out_path):
    """Скачивает файл с Яндекс.Диска по публичной ссылке"""
    # 1. Метаданные
    api_url = f"https://cloud-api.yandex.net/v1/disk/public/resources?public_key={urllib.parse.quote(public_key)}&limit=100"
    req = urllib.request.Request(api_url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    
    # 2. Найди файл
    download_url = None
    for item in data['_embedded']['items']:
        if item['name'] == filename:
            download_url = item['file']
            break
    if not download_url:
        raise FileNotFoundError(f"{filename} not found in {public_key}")
    
    # 3. Скачай
    req = urllib.request.Request(download_url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=300) as resp, open(out_path, "wb") as f:
        shutil.copyfileobj(resp, f)
    return out_path

# Использование:
download_from_yadisk(
    "https://disk.yandex.ru/d/2fJ1ubFFphvc-g",
    "Вилена.fbx",
    "/opt/data/workspace/dsh_model_split/input/Вилена.fbx"
)
```

## Важные нюансы
- **Timeout**: для больших файлов ставь 300-600 сек
- **User-Agent**: обязателен, иначе 403
- **Путь в API**: для файла в корне папки используй `path=%2Ffilename.fbx` (URL-encoded `/`)
- **Ссылка `file`** в ответе API уже содержит токен и готова к скачиванию
- Если файл не в корне, а в подпапке — указывай полный путь от корня публичной папки