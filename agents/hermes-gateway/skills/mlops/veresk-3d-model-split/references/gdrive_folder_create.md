# Google Drive — создание папок через JSON POST

## Проблема
Попытка создать папку через `multipart/related` (как обычный файл) возвращает **401 Unauthorized**, даже с валидным токеном.

## Причина
Google Drive API требует **разные эндпоинты/форматы** для разных операций:
- **Файлы** → `POST /upload/drive/v3/files?uploadType=multipart` с `multipart/related`
- **Папки** → `POST /drive/v3/files` с `application/json` (обычный JSON, НЕ multipart)

## Решение

### ❌ НЕПРАВИЛЬНО — multipart для папки
```python
# Это НЕ сработает — 401
metadata = {"name": "folder", "parents": [parent_id], "mimeType": "application/vnd.google-apps.folder"}
# multipart запрос...
```

### ✅ ПРАВИЛЬНО — JSON POST
```python
def create_folder(parent_id, name, access_token):
    metadata = {
        "name": name,
        "parents": [parent_id],
        "mimeType": "application/vnd.google-apps.folder"
    }
    data = json.dumps(metadata).encode()
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        "Content-Length": str(len(data))
    }
    req = urllib.request.Request(
        "https://www.googleapis.com/drive/v3/files",
        data=data, headers=headers, method="POST"
    )
    with urllib.request.urlopen(req) as r:
        return json.load(r)["id"]
```

## Поиск или создание (get_or_create)
```python
def get_or_create_folder(parent_id, name, access_token):
    # 1. Поиск
    q = urllib.parse.quote(f"name='{name}' and '{parent_id}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false")
    req = urllib.request.Request(
        f"https://www.googleapis.com/drive/v3/files?q={q}&fields=files(id,name)",
        headers={"Authorization": f"Bearer {access_token}"}, method="GET"
    )
    with urllib.request.urlopen(req) as r:
        resp = json.load(r)
        if resp.get("files"):
            return resp["files"][0]["id"]
    
    # 2. Создание (JSON POST)
    return create_folder(parent_id, name, access_token)
```

## Резюме
| Операция | Endpoint | Content-Type | Тело |
|----------|----------|--------------|------|
| Загрузка файла | `/upload/drive/v3/files?uploadType=multipart` | `multipart/related` | multipart body |
| Создание папки | `/drive/v3/files` | `application/json` | JSON metadata |
| Поиск файлов | `/drive/v3/files?q=...` | — | — (GET) |