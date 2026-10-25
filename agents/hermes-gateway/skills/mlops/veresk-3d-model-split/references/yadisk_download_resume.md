# Яндекс.Диск: скачивание больших файлов с докачкой и прогрессом

## Проблема
Публичные ссылки Яндекс.Диска (`https://disk.yandex.ru/d/...`) живут недолго (часто < 1 часа). Прямое скачивание `wget/curl` часто падает с 403/404 или таймаутом на больших файлах (>50 MB).

## Решение: API + Range Requests

### 1. Получить актуальную прямую ссылку
```python
import requests

def get_direct_url(public_key: str, path: str) -> str:
    """path — путь к файлу внутри публичной папки, начинается с /"""
    api = "https://cloud-api.yandex.net/v1/disk/public/resources"
    r = requests.get(api, params={"public_key": public_key, "path": path}, timeout=30)
    r.raise_for_status()
    return r.json()["file"]  # прямая ссылка, живет ~1 час
```

### 2. Скачивание с докачкой (Range) и прогрессом
```python
def download_with_resume(url: str, dest: str, chunk_size: int = 1024*1024):
    # Проверить размер
    head = requests.head(url, timeout=30)
    total = int(head.headers.get("Content-Length", 0))
    
    existing = os.path.getsize(dest) if os.path.exists(dest) else 0
    if existing >= total:
        return  # уже скачан
    
    headers = {"Range": f"bytes={existing}-"} if existing else {}
    mode = "ab" if existing else "wb"
    downloaded = existing
    last_report = time.time()
    
    with requests.get(url, headers=headers, stream=True, timeout=300) as r:
        r.raise_for_status()
        with open(dest, mode) as f:
            for chunk in r.iter_content(chunk_size=chunk_size):
                if chunk:
                    f.write(chunk)
                    downloaded += len(chunk)
                    
                    # Отчёт каждые 30 сек
                    if time.time() - last_report > 30:
                        pct = downloaded / total * 100 if total else 0
                        speed = downloaded / (time.time() - last_report + 1e-3) / 1024 / 1024
                        print(f"[PROGRESS] {downloaded/1024/1024:.1f}/{total/1024/1024:.1f} MB ({pct:.1f}%) @ {speed:.2f} MB/s")
                        last_report = time.time()
```

### 3. Фоновый запуск через Hermes (notify_on_complete)
```python
# В terminal tool:
terminal(
    command="python3 /path/download_yadisk.py",
    background=True,
    notify_on_complete=True,
    timeout=1800,
    workdir="/home/dsh/workspace/dsh_model_split"
)
# Вернёт session_id — можно делать process(action="poll") для промежуточных логов
```

### 4. Статус-файл для внешнего мониторинга
```python
# В цикле скачивания:
status = {
    "downloaded_mb": round(downloaded / 1024 / 1024, 1),
    "total_mb": round(total / 1024 / 1024, 1),
    "percent": round(pct, 1),
    "speed_mbps": round(speed, 2),
    "timestamp": time.strftime("%H:%M:%S")
}
with open("/home/dsh/workspace/dsh_model_split/download_status.json", "w") as sf:
    json.dump(status, sf)
```
Тогда можно читать `download_status.json` извне каждые 5 минут.

---

## Пример полного скрипта
См. `scripts/download_yadisk.py` (добавить в скилл).

---

## Важные нюансы
- **User-Agent**: Яндекс иногда блокирует дефолтный `python-requests`. Добавь заголовок: `headers={"User-Agent": "Mozilla/5.0 ..."}`
- **Redirects**: Прямая ссылка может редиректить — `requests` следует автоматически (`allow_redirects=True` по умолчанию)
- **Rate limits**: Не качай параллельно >2 файла с одного IP
- **Resume**: Сервер Яндекса поддерживает `Accept-Ranges: bytes` — докачка работает
- **Путь внутри папки**: В API указывается путь **с ведущим слешем** (`/Вилена.fbx`), даже если это корень папки
- **403/404 на больших файлах**: Прямые ссылки устаревают быстро. Всегда вызывай `get_direct_url()` **сразу перед скачиванием**, не кэшируй ссылку между запусками
- **Ограничение сети**: На медленных/нестабильных каналах 79 MB может качаться 30+ минут. Используй `timeout=300-600`, `background=true`, `notify_on_complete=true`
- **Отчёты прогресса**: Пользователь просит статус каждые **5 минут** для длительных задач. Статус-файл (`download_status.json`) обновляется каждые 30 сек скриптом — читай его внешне и отправляй отчёт пользователю