import os
import json
import urllib.request
import urllib.parse

# ============================================================
# КОНФИГУРАЦИЯ GOOGLE DRIVE
# ============================================================
TOKEN_PATH = "/opt/data/google_token.json"
ROOT_FOLDER_ID = "1B5IG-mIHgJdqUXqxANzfEDzXx0Z8pzbY"  # 3dmodels
PARTS_DIR = "/opt/data/workspace/dsh_model_split/veresk2/model"
RENDER_DIR = "/opt/data/workspace/dsh_model_split/veresk2/render"

with open(TOKEN_PATH) as f:
    tok = json.load(f)

def headers():
    return {"Authorization": f"Bearer {tok['access_token']}"}

def refresh_token():
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": tok["refresh_token"],
        "client_id": tok["client_id"],
        "client_secret": tok["client_secret"],
    }).encode()
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token", data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"}, method="POST"
    )
    with urllib.request.urlopen(req) as r:
        resp = json.load(r)
        tok["access_token"] = resp["access_token"]
        with open(TOKEN_PATH, "w") as f:
            json.dump(tok, f, indent=2)

# Обновляем токен сразу при запуске
refresh_token()
def get_or_create_folder(parent_id, name):
    """Найти или создать папку на Google Drive"""
    q = urllib.parse.quote(f"name='{name}' and '{parent_id}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false")
    req = urllib.request.Request(
        f"https://www.googleapis.com/drive/v3/files?q={q}&fields=files(id,name)",
        headers=headers(), method="GET"
    )
    try:
        with urllib.request.urlopen(req) as r:
            resp = json.load(r)
            if resp.get("files"):
                return resp["files"][0]["id"]
    except:
        pass
    # Создание папки через обычный JSON POST (не multipart)
    metadata = {"name": name, "parents": [parent_id], "mimeType": "application/vnd.google-apps.folder"}
    data = json.dumps(metadata).encode()
    h = headers()
    h["Content-Type"] = "application/json"
    h["Content-Length"] = str(len(data))
    req = urllib.request.Request(
        "https://www.googleapis.com/drive/v3/files",
        data=data, headers=h, method="POST"
    )
    with urllib.request.urlopen(req) as r:
        return json.load(r)["id"]

def upload_file(local_path, drive_name, parent_id):
    boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
    with open(local_path, "rb") as f:
        file_data = f.read()
    metadata = {"name": drive_name, "parents": [parent_id]}
    parts = [
        f"--{boundary}", "Content-Type: application/json; charset=UTF-8", "",
        json.dumps(metadata), f"--{boundary}", "Content-Type: application/octet-stream", ""
    ]
    head = "\r\n".join(parts).encode() + b"\r\n"
    foot = b"\r\n--" + boundary.encode() + b"--\r\n"
    body = head + file_data + foot
    h = headers()
    h["Content-Type"] = f"multipart/related; boundary={boundary}"
    h["Content-Length"] = str(len(body))
    req = urllib.request.Request(
        "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart",
        data=body, headers=h, method="POST"
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)["id"]
    except urllib.error.HTTPError as e:
        if e.code == 401:
            refresh_token()
            h = headers()
            h["Content-Type"] = f"multipart/related; boundary={boundary}"
            h["Content-Length"] = str(len(body))
            req = urllib.request.Request(
                "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart",
                data=body, headers=h, method="POST"
            )
            with urllib.request.urlopen(req) as r:
                return json.load(r)["id"]
        raise

# ===== Основная загрузка =====

# 1. Создаём/находим папку veresk2 в 3dmodels
print("Создаём папку veresk2...")
veresk2_id = get_or_create_folder(ROOT_FOLDER_ID, "veresk2")

# 2. Создаём папки model и render внутри veresk2
print("Создаём папку model...")
model_id = get_or_create_folder(veresk2_id, "model")
print("Создаём папку render...")
render_id = get_or_create_folder(veresk2_id, "render")

# 3. Загружаем модели
print("Загружаем модели...")
with open(os.path.join(PARTS_DIR, "groups.json")) as f:
    groups = json.load(f)

for name in sorted(groups.keys()):
    local = os.path.join(PARTS_DIR, f"{name}.fbx")
    if os.path.exists(local):
        fid = upload_file(local, f"{name}.fbx", model_id)
        print(f"  {name}.fbx -> https://drive.google.com/file/d/{fid}")

# 4. Загружаем рендеры
print("Загружаем рендеры...")
for name in sorted(groups.keys()):
    local = os.path.join(RENDER_DIR, f"{name}_iso.png")
    if os.path.exists(local):
        fid = upload_file(local, f"{name}_iso.png", render_id)
        print(f"  {name}_iso.png -> https://drive.google.com/file/d/{fid}")

print("Upload complete!")