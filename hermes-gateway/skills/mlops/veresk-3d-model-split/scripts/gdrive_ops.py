#!/usr/bin/env python3
"""
Google Drive операции для пайплайна veresk-3d-model-split.

Только stdlib (urllib). Поддерживает:
  - resolve_folder_id()  — ссылка на папку Drive (/folders/ID, ?id=ID, голый ID) -> ID
  - list_fbx()           — рекурсивный список .fbx в папке
  - download_file()      — скачивание файла по ID
  - find_or_create_folder() / upload_file()

Особенности, важные для работоспособности:
  - access_token() сам обновляет access_token через refresh_token (401 -> refresh -> retry)
  - Папки создаются ТОЛЬКО через JSON POST (multipart для папок даёт 401)
  - multipart/related: ровно ОДНА пустая строка после Content-Type файла
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ============================================================
# КОНФИГУРАЦИЯ
# ============================================================
TOKEN_PATHS = [
    "/opt/data/google_token.json",
    os.path.expanduser("~/.hermes/google_token.json"),
]
DRIVE_API = "https://www.googleapis.com/drive/v3"
UPLOAD_API = "https://www.googleapis.com/upload/drive/v3"
FOLDER_MIME = "application/vnd.google-apps.folder"
TIMEOUT = 300
# ============================================================


# ---------------------------------------------------------- ТОКЕН
def _load_token():
    for p in TOKEN_PATHS:
        if os.path.exists(p):
            with open(p) as f:
                return json.load(f), p
    raise FileNotFoundError(
        "Google токен не найден. Ожидался один из: %s" % ", ".join(TOKEN_PATHS)
    )


def refresh_token():
    """Обновить access_token через refresh_token и записать обратно в файл."""
    tok, path = _load_token()
    data = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": tok["refresh_token"],
            "client_id": tok["client_id"],
            "client_secret": tok["client_secret"],
        }
    ).encode()
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        resp = json.load(r)
    tok["access_token"] = resp["access_token"]
    with open(path, "w") as f:
        json.dump(tok, f, indent=2)
    return tok["access_token"]


def access_token(force_refresh=False):
    """Вернуть валидный access_token (при force_refresh — обновить принудительно)."""
    tok, _ = _load_token()
    if force_refresh or not tok.get("access_token"):
        return refresh_token()
    return tok["access_token"]


def _hdrs(extra=None):
    h = {"Authorization": "Bearer %s" % access_token()}
    if extra:
        h.update(extra)
    return h


def _get_json(url, params=None, retry=True):
    """GET к Drive API с автоматическим обновлением токена при 401."""
    full_url = url + "?" + urllib.parse.urlencode(params) if params else url
    req = urllib.request.Request(full_url, headers=_hdrs(), method="GET")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 401 and retry:
            # ВАЖНО: повторяем БАЗОВЫЙ url + params, а не уже склеенный full_url,
            # иначе query-параметры продублируются и запрос снова даст 401.
            refresh_token()
            return _get_json(url, params, retry=False)
        body = ""
        try:
            body = e.read().decode()[:600]
        except Exception:
            pass
        raise RuntimeError("Drive API %s: HTTP %s %s" % (full_url[:140], e.code, body))


# ---------------------------------------------------------- ССЫЛКИ
def resolve_folder_id(ref):
    """
    Принимает ссылку на папку Google Drive или её ID и возвращает ID папки.
    Поддерживаемые форматы:
      https://drive.google.com/drive/folders/<ID>
      https://drive.google.com/drive/folders/<ID>/view?usp=sharing
      https://drive.google.com/open?id=<ID>
      https://drive.google.com/uc?id=<ID>&export=download
      https://drive.google.com/drive/u/0/folders/<ID>/view
      <ID>  (голый ID, 20+ символов [A-Za-z0-9_-])
    """
    if not ref:
        raise ValueError("Пустая ссылка на папку")
    ref = ref.strip().strip('"').strip("'")

    m = re.search(r"/folders/([A-Za-z0-9_-]+)", ref)
    if m:
        return m.group(1)

    m = re.search(r"[?&]id=([A-Za-z0-9_-]+)", ref)
    if m:
        return m.group(1)

    m = re.fullmatch(r"[A-Za-z0-9_-]{20,}", ref)
    if m:
        return ref

    raise ValueError(
        "Не удалось извлечь ID папки из ссылки: %s\n"
        "Ожидается https://drive.google.com/drive/folders/<ID>" % ref
    )


def folder_url(folder_id):
    return "https://drive.google.com/drive/folders/%s" % folder_id


def file_url(file_id):
    return "https://drive.google.com/file/d/%s/view" % file_id


# ---------------------------------------------------------- ЧТЕНИЕ
def list_children(folder_id):
    """Все не-удалённые объекты внутри папки (файлы + подпапки)."""
    items = []
    page_token = None
    while True:
        params = {
            "q": "'%s' in parents and trashed=false" % folder_id,
            "fields": "nextPageToken,files(id,name,mimeType,size,modifiedTime)",
            "pageSize": "200",
            "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
            "orderBy": "folder,name_natural",
        }
        if page_token:
            params["pageToken"] = page_token
        resp = _get_json(DRIVE_API + "/files", params)
        items.extend(resp.get("files", []))
        page_token = resp.get("nextPageToken")
        if not page_token:
            break
    return items


def list_fbx(folder_id, recursive=True):
    """
    Список .fbx файлов в папке.
    recursive=True — обходить вложенные папки (поле subfolder — путь от корня).
    Возвращает [{id, name, size, subfolder, relpath}]
    """
    found = []
    stack = [(folder_id, "")]
    seen = set()
    while stack:
        fid, prefix = stack.pop(0)
        if fid in seen:
            continue
        seen.add(fid)
        for it in list_children(fid):
            name = it.get("name", "")
            if it.get("mimeType") == FOLDER_MIME:
                if recursive:
                    stack.append((it["id"], (prefix + "/" + name) if prefix else name))
                continue
            if name.lower().endswith(".fbx"):
                found.append(
                    {
                        "id": it["id"],
                        "name": name,
                        "size": int(it.get("size", 0) or 0),
                        "mimeType": it.get("mimeType", ""),
                        "modifiedTime": it.get("modifiedTime", ""),
                        "subfolder": prefix,
                        "relpath": (prefix + "/" + name) if prefix else name,
                        "url": file_url(it["id"]),
                    }
                )
    found.sort(key=lambda x: x["relpath"].lower())
    return found


def download_file(file_id, dest_path, show_progress=False):
    """Скачать файл Drive по ID в dest_path (с прогрессом в stderr)."""
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    url = "%s/files/%s?alt=media" % (DRIVE_API, file_id)
    req = urllib.request.Request(url, headers=_hdrs(), method="GET")
    try:
        resp = urllib.request.urlopen(req, timeout=TIMEOUT)
    except urllib.error.HTTPError as e:
        if e.code == 401:
            refresh_token()
            req = urllib.request.Request(url, headers=_hdrs(), method="GET")
            resp = urllib.request.urlopen(req, timeout=TIMEOUT)
        else:
            raise RuntimeError("Не удалось скачать %s: HTTP %s" % (file_id, e.code))

    total = int(resp.headers.get("Content-Length") or 0)
    got = 0
    t0 = time.time()
    with open(dest_path, "wb") as f:
        while True:
            chunk = resp.read(1024 * 256)
            if not chunk:
                break
            f.write(chunk)
            got += len(chunk)
            if show_progress and time.time() - t0 > 1:
                t0 = time.time()
                pct = (got * 100.0 / total) if total else 0
                sys.stderr.write(
                    "\r  %.1f%%  %.1f/%.1f MB" % (pct, got / 1048576.0, total / 1048576.0)
                )
                sys.stderr.flush()
    if show_progress:
        sys.stderr.write("\n")
    return dest_path


# ---------------------------------------------------------- ЗАПИСЬ
def create_folder(parent_id, name):
    """Создать папку. ТОЛЬКО application/json POST (multipart -> 401)."""
    metadata = {"name": name, "parents": [parent_id], "mimeType": FOLDER_MIME}
    data = json.dumps(metadata).encode()
    req = urllib.request.Request(
        DRIVE_API + "/files",
        data=data,
        headers=_hdrs(
            {"Content-Type": "application/json; charset=UTF-8",
             "Content-Length": str(len(data))}
        ),
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.load(r)["id"]
    except urllib.error.HTTPError as e:
        if e.code == 401:
            refresh_token()
            return create_folder(parent_id, name)
        body = ""
        try:
            body = e.read().decode()[:400]
        except Exception:
            pass
        raise RuntimeError("Не удалось создать папку '%s': HTTP %s %s" % (name, e.code, body))


def find_or_create_folder(parent_id, name):
    """Найти папку по имени среди детей parent_id, иначе создать."""
    for it in list_children(parent_id):
        if it.get("mimeType") == FOLDER_MIME and it.get("name") == name:
            return it["id"]
    return create_folder(parent_id, name)


def upload_file(local_path, drive_name, parent_id):
    """Загрузить локальный файл в папку parent_id под именем drive_name."""
    boundary = "----HermesVereskBoundary7MA4YWxkTrZu0gW"
    with open(local_path, "rb") as f:
        file_data = f.read()

    metadata = {"name": drive_name, "parents": [parent_id]}
    # ВАЖНО: между заголовком файла и данными — РОВНО ОДНА пустая строка
    parts = [
        "--%s" % boundary,
        "Content-Type: application/json; charset=UTF-8",
        "",
        json.dumps(metadata),
        "--%s" % boundary,
        "Content-Type: application/octet-stream",
        "",
    ]
    head = "\r\n".join(parts).encode() + b"\r\n"
    foot = b"\r\n--" + boundary.encode() + b"--\r\n"
    body = head + file_data + foot

    def _post():
        h = _hdrs(
            {
                "Content-Type": "multipart/related; boundary=%s" % boundary,
                "Content-Length": str(len(body)),
            }
        )
        req = urllib.request.Request(
            UPLOAD_API + "/files?uploadType=multipart&supportsAllDrives=true",
            data=body,
            headers=h,
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.load(r)["id"]

    try:
        return _post()
    except urllib.error.HTTPError as e:
        if e.code == 401:
            refresh_token()
            return _post()
        body_txt = ""
        try:
            body_txt = e.read().decode()[:400]
        except Exception:
            pass
        raise RuntimeError("Ошибка загрузки %s: HTTP %s %s" % (drive_name, e.code, body_txt))


def delete_file(file_id):
    """Удалить файл/папку по ID (для очистки при повторной обработке)."""
    req = urllib.request.Request(
        DRIVE_API + "/files/%s" % file_id, headers=_hdrs(), method="DELETE"
    )
    try:
        urllib.request.urlopen(req, timeout=60)
        return True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return True
        raise


# ---------------------------------------------------------- CLI (для отладки)
def _main(argv):
    import argparse

    ap = argparse.ArgumentParser(description="Google Drive утилиты")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list", help="показать .fbx в папке")
    p.add_argument("folder")
    p.add_argument("--flat", action="store_true", help="без рекурсии")

    p = sub.add_parser("probe", help="проверить доступ к папке")
    p.add_argument("folder")

    p = sub.add_parser("get", help="скачать файл по ID")
    p.add_argument("file_id")
    p.add_argument("dest")

    args = ap.parse_args(argv)

    if args.cmd == "list":
        fid = resolve_folder_id(args.folder)
        files = list_fbx(fid, recursive=not args.flat)
        print(json.dumps({"folder_id": fid, "count": len(files), "files": files},
                         ensure_ascii=False, indent=2))
    elif args.cmd == "probe":
        fid = resolve_folder_id(args.folder)
        meta = _get_json(
            DRIVE_API + "/files/" + fid,
            {"fields": "id,name,mimeType,owners(emailAddress)", "supportsAllDrives": "true"},
        )
        print(json.dumps(meta, ensure_ascii=False, indent=2))
    elif args.cmd == "get":
        print(download_file(args.file_id, args.dest, show_progress=True))


if __name__ == "__main__":
    _main(sys.argv[1:])