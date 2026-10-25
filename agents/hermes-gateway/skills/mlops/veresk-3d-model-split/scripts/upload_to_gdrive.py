import os
import json
import urllib.request
import urllib.parse

# ============================================================
# КОНФИГУРАЦИЯ GOOGLE DRIVE
# ============================================================
TOKEN_PATH = "/opt/data/google_token.json"
FOLDER_ID = "1B5IG-mIHgJdqUXqxANzfEDzXx0Z8pzbY"  # ID папки 3dmodels на Google Drive
VERESK2_FOLDER_ID = None  # будет создано автоматически
PARTS_DIR = "/opt/data/workspace/dsh_model_split/veresk2/model"
RENDER_DIR = "/opt/data/workspace/dsh_model_split/veresk2/render"

# Имена файлов на Google Drive (1.fbx, 2.fbx... + 1_iso.png, 2_iso.png...)
def get_drive_files(groups):
    """Генерирует список файлов для загрузки на основе групп"""
    files = []
    for i, name in enumerate(sorted(groups.keys()), 1):
        base = str(i)
        files.append((os.path.join(PARTS_DIR, f"{name}.fbx"), f"{base}.fbx"))
        files.append((os.path.join(RENDER_DIR, f"{name}_iso.png"), f"{base}_iso.png"))
    return files
# ============================================================

with open(TOKEN_PATH) as f:
    tok = json.load(f)

def headers():
    return {"Authorization": f"Bearer {tok['access_token']}"}

def refresh_token():
    """Обновляем access token через refresh_token"""
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": tok["refresh_token"],
        "client_id": tok["client_id"],
        "client_secret": tok["client_secret"],
    }).encode()
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST"
    )
    with urllib.request.urlopen(req) as r:
        resp = json.load(r)
        tok["access_token"] = resp["access_token"]
        with open(TOKEN_PATH, "w") as f:
            json.dump(tok, f, indent=2)

def upload_file(local_path, drive_name):
    """Загружает файл на Google Drive через multipart загрузку"""
    boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
    
    with open(local_path, "rb") as f:
        file_data = f.read()
    
    metadata = {"name": drive_name, "parents": [FOLDER_ID]}
    
    parts = [
        f"--{boundary}",
        "Content-Type: application/json; charset=UTF-8",
        "",
        json.dumps(metadata),
        f"--{boundary}",
        "Content-Type: application/octet-stream",
        "",
    ]
    
    head = "\r\n".join(parts).encode() + b"\r\n"
    foot = b"\r\n--" + boundary.encode() + b"--\r\n"
    body = head + file_data + foot
    
    h = headers()
    h["Content-Type"] = f"multipart/related; boundary={boundary}"
    h["Content-Length"] = str(len(body))
    
    req = urllib.request.Request(
        "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart",
        data=body,
        headers=h,
        method="POST"
    )
    
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)["id"]
    except urllib.error.HTTPError as e:
        if e.code == 401:  # Токен истёк
            refresh_token()
            h = headers()
            h["Content-Type"] = f"multipart/related; boundary={boundary}"
            h["Content-Length"] = str(len(body))
            req = urllib.request.Request(
                "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart",
                data=body,
                headers=h,
                method="POST"
            )
            with urllib.request.urlopen(req) as r:
                return json.load(r)["id"]
        raise

# Основная загрузка
with open(os.path.join(PARTS_DIR, "groups.json")) as f:
    groups = json.load(f)

files_to_upload = get_drive_files(groups)

for local_path, drive_name in files_to_upload:
    if os.path.exists(local_path):
        try:
            file_id = upload_file(local_path, drive_name)
            print(f"https://drive.google.com/file/d/{file_id}")
        except Exception as e:
            print(f"Error uploading {drive_name}: {e}")
    else:
        print(f"File not found: {local_path}")

print("Upload complete!")