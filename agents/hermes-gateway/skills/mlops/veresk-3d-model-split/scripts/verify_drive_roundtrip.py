"""Проверка загрузок на Google Drive: обратное скачивание + сверка md5.

  python3 verify_drive_roundtrip.py --manifest upload_result.json [--dir /tmp/dl]

HTTP 200 на загрузке подтверждает создание записи, а не целостность
содержимого. Единственная надёжная проверка — скачать обратно и сравнить
размер и md5 с локальным файлом.

Формат manifest: {"folder": "<id>",
                  "files": [{"name": "7.fbx", "id": "<id>", "size": 574412}, ...]}
Печатает ROUND_TRIP: ALL OK либо список расхождений.
"""
import os, sys, json, hashlib, urllib.request, urllib.error

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
A = {}
i = 0
while i < len(argv):
    if argv[i].startswith("--"):
        A[argv[i][2:]] = argv[i + 1] if i + 1 < len(argv) else ""
        i += 2
    else:
        i += 1

TOKEN_PATH = A.get("token", "/opt/data/google_token.json")
MANIFEST = A["manifest"]
BASE = A.get("dir", "/tmp/dr_dl")
TOL = int(A.get("tol", 0))          # допуск по размеру, байт

os.makedirs(BASE, exist_ok=True)
with open(MANIFEST) as f:
    man = json.load(f)
with open(TOKEN_PATH) as f:
    tok = json.load(f)


def auth():
    return {"Authorization": "Bearer " + tok["access_token"]}


def refresh():
    import urllib.parse
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token", "refresh_token": tok["refresh_token"],
        "client_id": tok["client_id"], "client_secret": tok["client_secret"],
    }).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"}, method="POST")
    with urllib.request.urlopen(req) as r:
        tok["access_token"] = json.load(r)["access_token"]
    with open(TOKEN_PATH, "w") as f:
        json.dump(tok, f, indent=2)
    print("TOKEN_REFRESHED", flush=True)


def fetch(fid):
    url = "https://www.googleapis.com/drive/v3/files/%s?alt=media" % fid
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=auth())) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        if e.code == 401:
            refresh()
            with urllib.request.urlopen(urllib.request.Request(url, headers=auth())) as r:
                return r.read()
        raise


def md5(b):
    return hashlib.md5(b).hexdigest()


ok = True
for f in man["files"]:
    name, fid = f["name"], f["id"]
    local = os.path.join(BASE, "dl_" + name)
    try:
        blob = fetch(fid)
        with open(local, "wb") as fh:
            fh.write(blob)
        size_ok = abs(len(blob) - f.get("size", len(blob))) <= TOL
        # локальный эталон: если есть рядом — сверяем и с ним
        cand = [p for p in (os.path.join(BASE, name), name) if os.path.exists(p)]
        ref_ok = True
        if cand:
            with open(cand[0], "rb") as fh:
                ref_ok = md5(fh.read()) == md5(blob)
        good = size_ok and ref_ok
        ok = ok and good
        print("%-14s drive=%-8d expected=%-8s md5 %s  %s"
              % (name, len(blob), f.get("size", "-"), md5(blob)[:10],
                 "OK" if good else "MISMATCH"), flush=True)
    except Exception as e:
        ok = False
        print("%-14s ERROR %s" % (name, e), flush=True)

print("ROUND_TRIP: " + ("ALL OK" if ok else "PROBLEM"), flush=True)
sys.exit(0 if ok else 1)