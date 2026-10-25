"""Загрузка 152 новых рендеров в ОТДЕЛЬНУЮ папку для проверки.

Старые 211 файлов в models/ и renders/ НЕ трогает — ничего не удаляет.
"""
import os, json, hashlib, time, sys, urllib.request, urllib.parse, urllib.error

TOKEN_PATH = "/opt/data/google_token.json"
ID_DARIO = "1OEusjCLX6LGNo6gIiDeT99PVlfUjNfem"   # папка "Дарио"
NEW_FOLDER = "renders_fixed_152"
RENDERS = "/opt/data/workspace/dsh_model_split/Dario/renders_fixed"

tok = json.load(open(TOKEN_PATH))


def refresh():
    dd = urllib.parse.urlencode({
        "grant_type": "refresh_token", "refresh_token": tok["refresh_token"],
        "client_id": tok["client_id"], "client_secret": tok["client_secret"]}).encode()
    r = urllib.request.Request("https://oauth2.googleapis.com/token", data=dd,
                               headers={"Content-Type": "application/x-www-form-urlencoded"},
                               method="POST")
    tok["access_token"] = json.load(urllib.request.urlopen(r))["access_token"]
    json.dump(tok, open(TOKEN_PATH, "w"), indent=2)


H = lambda: {"Authorization": "Bearer " + tok["access_token"]}


def get(url):
    r = urllib.request.Request(url, headers=H(), method="GET")
    try:
        return json.load(urllib.request.urlopen(r, timeout=120))
    except urllib.error.HTTPError as e:
        if e.code == 401:
            refresh()
            r = urllib.request.Request(url, headers=H(), method="GET")
            return json.load(urllib.request.urlopen(r, timeout=120))
        raise


def listdir(fid):
    out, page = [], None
    while True:
        q = urllib.parse.quote("'%s' in parents and trashed=false" % fid)
        url = ("https://www.googleapis.com/drive/v3/files?q=%s&fields="
               "nextPageToken,files(id,name,size)&pageSize=1000" % q)
        if page:
            url += "&pageToken=" + page
        j = get(url)
        out += j.get("files", [])
        page = j.get("nextPageToken")
        if not page:
            return out


def create_folder(name, parent):
    body = json.dumps({"name": name, "mimeType": "application/vnd.google-apps.folder",
                       "parents": [parent]}).encode()
    r = urllib.request.Request("https://www.googleapis.com/drive/v3/files",
                               data=body, headers={**H(), "Content-Type": "application/json"},
                               method="POST")
    try:
        return json.load(urllib.request.urlopen(r, timeout=120))["id"]
    except urllib.error.HTTPError as e:
        if e.code == 401:
            refresh()
            r = urllib.request.Request("https://www.googleapis.com/drive/v3/files", data=body,
                                       headers={**H(), "Content-Type": "application/json"},
                                       method="POST")
            return json.load(urllib.request.urlopen(r, timeout=120))["id"]
        raise


def upload(path, name, parent, retries=3):
    b = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
    data = open(path, "rb").read()
    meta = {"name": name, "parents": [parent]}
    parts = [f"--{b}", "Content-Type: application/json; charset=UTF-8", "",
             json.dumps(meta), f"--{b}", "Content-Type: application/octet-stream", ""]
    body = ("\r\n".join(parts).encode() + b"\r\n" + data
            + b"\r\n--" + b.encode() + b"--\r\n")
    for attempt in range(retries):
        h = H()
        h["Content-Type"] = "multipart/related; boundary=%s" % b
        h["Content-Length"] = str(len(body))
        req = urllib.request.Request(
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart",
            data=body, headers=h, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                return json.load(r)["id"]
        except urllib.error.HTTPError as e:
            if e.code == 401:
                refresh()
                continue
            if e.code in (403, 429, 500, 502, 503) and attempt < retries - 1:
                time.sleep(5 * (attempt + 1))
                continue
            raise
    raise RuntimeError("не загружено после %d попыток" % retries)


def md5f(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


refresh()

files = sorted((f for f in os.listdir(RENDERS) if f.endswith(".png")),
               key=lambda s: int(s.split("_")[0]))
print("локальных рендеров: %d" % len(files), flush=True)

# найти/создать папку
existing = {f["name"]: f["id"] for f in listdir(ID_DARIO)}
if NEW_FOLDER in existing:
    fid = existing[NEW_FOLDER]
    have = {f["name"] for f in listdir(fid)}
    print("папка уже есть: %s, файлов в ней: %d" % (fid, len(have)), flush=True)
else:
    fid = create_folder(NEW_FOLDER, ID_DARIO)
    have = set()
    print("создана папка: %s (%s)" % (fid, NEW_FOLDER), flush=True)

todo = [f for f in files if f not in have]
print("к загрузке: %d (уже было: %d)" % (len(todo), len(files) - len(todo)), flush=True)

t0 = time.time()
done = failed = 0
for i, fn in enumerate(todo, 1):
    try:
        upload(os.path.join(RENDERS, fn), fn, fid)
        done += 1
    except Exception as e:
        failed += 1
        print("  ОШИБКА %s: %s" % (fn, e), flush=True)
    if i % 25 == 0 or i == len(todo):
        el = time.time() - t0
        eta = el / i * (len(todo) - i)
        print("  %d/%d  %.0f сек  ETA %.0f сек" % (i, len(todo), el, eta), flush=True)

print("ЗАГРУЖЕНО %d, ошибок %d" % (done, failed), flush=True)

print("\n=== ПРОВЕРКА ===", flush=True)
remote = {f["name"]: int(f["size"]) for f in listdir(fid)}
local = {fn: os.path.getsize(os.path.join(RENDERS, fn)) for fn in files}
miss = [k for k in local if k not in remote]
bad = [k for k in local if k in remote and remote[k] != local[k]]
extra = [k for k in remote if k not in local]
print("локально %d | Drive %d | нет %d | размер не совпал %d | лишних %d"
      % (len(local), len(remote), len(miss), len(bad), len(extra)), flush=True)
if miss:
    print("  НЕТ: %s" % miss[:10], flush=True)
if bad:
    print("  РАЗМЕР: %s" % bad[:10], flush=True)

ok = not (miss or bad)
# md5 round-trip на выборке
rem_ids = {f["name"]: f["id"] for f in listdir(fid)}
for nm in [files[0], files[len(files) // 2], files[-1]]:
    if nm not in rem_ids:
        print("  md5 %s: НЕТ НА DRIVE" % nm, flush=True)
        ok = False
        continue
    d = get("https://www.googleapis.com/drive/v3/files/%s?alt=media" % rem_ids[nm])
    print("  md5 %s: %s" % (nm, "OK" if hashlib.md5(d).hexdigest() == md5f(os.path.join(RENDERS, nm)) else "НЕСОВПАДЕНИЕ"), flush=True)

print("\nИТОГ: %s" % ("ВСЁ ОК" if ok and failed == 0 else "ЕСТЬ ПРОБЛЕМЫ"), flush=True)
print("Папка: https://drive.google.com/drive/folders/%s" % fid, flush=True)