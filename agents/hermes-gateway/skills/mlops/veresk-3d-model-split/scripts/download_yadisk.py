#!/usr/bin/env python3
"""
Скачивание файла с Яндекс.Диска (публичная папка) с докачкой, прогрессом и статус-файлом.

Usage:
    python3 download_yadisk.py "https://disk.yandex.ru/d/XXXX" "/путь/внутри/папки/файл.fbx" "/путь/куда/сохранить/файл.fbx"

Пример:
    python3 download_yadisk.py "https://disk.yandex.ru/d/2fJ1ubFFphvc-g" "/Вилена.fbx" "/home/dsh/workspace/dsh_model_split/input/Вилена.fbx"
"""

import sys
import os
import time
import json
import requests

CHUNK_SIZE = 1024 * 1024  # 1 MB
STATUS_FILE = "/home/dsh/workspace/dsh_model_split/download_status.json"
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"

def get_direct_url(public_key: str, path: str) -> str:
    """Получить актуальную прямую ссылку на файл в публичной папке Яндекс.Диска."""
    api_url = "https://cloud-api.yandex.net/v1/disk/public/resources"
    params = {"public_key": public_key, "path": path}
    headers = {"User-Agent": USER_AGENT}
    r = requests.get(api_url, params=params, headers=headers, timeout=30)
    r.raise_for_status()
    return r.json()["file"]

def download_with_resume(url: str, dest: str):
    """Скачать с докачкой (Range), писать прогресс в STATUS_FILE."""
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    
    head = requests.head(url, headers={"User-Agent": USER_AGENT}, timeout=30, allow_redirects=True)
    total_size = int(head.headers.get("Content-Length", 0))
    
    existing = os.path.getsize(dest) if os.path.exists(dest) else 0
    print(f"[INFO] Total: {total_size/1024/1024:.1f} MB, Existing: {existing/1024/1024:.1f} MB")
    
    if existing >= total_size:
        print("[INFO] Already complete")
        return True
    
    headers = {"User-Agent": USER_AGENT}
    if existing > 0:
        headers["Range"] = f"bytes={existing}-"
    
    mode = "ab" if existing > 0 else "wb"
    downloaded = existing
    last_report = time.time()
    
    with requests.get(url, headers=headers, stream=True, timeout=300, allow_redirects=True) as r:
        r.raise_for_status()
        with open(dest, mode) as f:
            for chunk in r.iter_content(chunk_size=CHUNK_SIZE):
                if chunk:
                    f.write(chunk)
                    downloaded += len(chunk)
                    
                    if time.time() - last_report > 30:
                        pct = downloaded / total_size * 100 if total_size else 0
                        speed = downloaded / (time.time() - last_report + 1e-3) / 1024 / 1024
                        status = {
                            "downloaded_mb": round(downloaded / 1024 / 1024, 1),
                            "total_mb": round(total_size / 1024 / 1024, 1),
                            "percent": round(pct, 1),
                            "speed_mbps": round(speed, 2),
                            "timestamp": time.strftime("%H:%M:%S")
                        }
                        with open(STATUS_FILE, "w") as sf:
                            json.dump(status, sf)
                        print(f"[PROGRESS] {status}")
                        last_report = time.time()
    
    print(f"[DONE] Downloaded {downloaded/1024/1024:.1f} MB")
    return True

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python3 download_yadisk.py <public_folder_url> <path_in_folder> <dest_path>")
        print('Example: python3 download_yadisk.py "https://disk.yandex.ru/d/ABC" "/file.fbx" "/tmp/file.fbx"')
        sys.exit(1)
    
    public_url = sys.argv[1]
    path_in_folder = sys.argv[2]
    dest_path = sys.argv[3]
    
    try:
        direct = get_direct_url(public_url, path_in_folder)
        print(f"[INFO] Got direct URL")
        download_with_resume(direct, dest_path)
    except Exception as e:
        print(f"[ERROR] {e}")
        with open(STATUS_FILE, "w") as sf:
            json.dump({"error": str(e), "timestamp": time.strftime("%H:%M:%S")}, sf)
        sys.exit(1)