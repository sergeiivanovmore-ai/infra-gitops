# Multipart Upload Fix — лишние переносы строк

## Проблема
При загрузке файлов на Google Drive через `multipart/related` PNG файлы становились невалидными — заголовок `89 50 4E 47...` смещался, появлялся мусор `0D 0A 89 50...`.

## Причина
В массиве `parts` было **две** пустые строки после `Content-Type: application/octet-stream`:

```python
# НЕПРАВИЛЬНО — две пустые строки
parts = [
    f"--{boundary}",
    "Content-Type: application/json; charset=UTF-8",
    "",
    json.dumps(metadata),
    f"--{boundary}",
    "Content-Type: application/octet-stream",
    "",     # ← пустая строка 1
    ""      # ← пустая строка 2 (ЛИШНЯЯ!)
]
```

Это создаёт в теле запроса лишний `\r\n` перед данными файла:
```
--boundary\r\n
Content-Type: application/octet-stream\r\n
\r\n           ← пустая строка 1 (нормально — конец заголовков)
\r\n           ← пустая строка 2 (ЛИШНЯЯ! попадает в файл)
PNG_DATA...
```

## Решение
Оставляй **ровно одну** пустую строку после заголовков части:

```python
# ПРАВИЛЬНО — одна пустая строка
parts = [
    f"--{boundary}",
    "Content-Type: application/json; charset=UTF-8",
    "",
    json.dumps(metadata),
    f"--{boundary}",
    "Content-Type: application/octet-stream",
    ""      # ← ровно ОДНА пустая строка = конец заголовков
]
head = "\r\n".join(parts).encode() + b"\r\n"
body = head + file_data + b"\r\n--" + boundary.encode() + b"--\r\n"
```

## Правильная структура multipart/related
```
--boundary\r\n
Content-Type: application/json; charset=UTF-8\r\n
\r\n
{"name": "file.fbx", "parents": ["folder_id"]}\r\n
--boundary\r\n
Content-Type: application/octet-stream\r\n
\r\n          ← ОДИН \r\n — конец заголовков, дальше бинарные данные
FILE_BYTES...
\r\n--boundary--\r\n
```

## Проверка
После загрузки скачай файл обратно и проверь заголовок:
```python
with open("downloaded.png", "rb") as f:
    header = f.read(8)
assert header == b"\x89PNG\r\n\x1a\n"  # правильный PNG заголовок
```

## Ключевой момент
Google Drive API `uploadType=multipart` ожитает **ровно** стандартную multipart структуру. Любой лишний `\r\n` перед `file_data` попадёт в сохранённый файл и испортит его.