"""Этап 2: подмена на Drive.

Порядок (безопасно — при сбое на любом шаге старое ещё на месте):
 1. Убедиться, что 152 новых FBX и 152 PNG лежат в новых папках и совпадают по размеру.
 2. Удалить 211 старых FBX (в корзину) и 211 старых PNG (в корзину).
 3. Переименовать новые папки в models / renders.
"""
import os, json, sys, time, urllib.request, urllib.parse, urllib.error

TOKEN_PATH = "/opt/data/google_token.json"
ID_DARIO = "1OEusjCLX6LGNo6gIiDeT99PVlfUjNfem"
ID_MODELS_OLD = "1DjAkrZwpZQ01peI8zyYr-_U-I5P9_9tj"
ID_RENDERS_OLD = "1KsdoB4nnl5zrCw-zADkW1jfBcRdGaN6i"
ID_RENDERS_NEW = "1dh4B7im4fO8Mu8A_6798ibBKziCpV41z"
D = "/opt/data/workspace/dsh_model_split/Dario"
PARTS = os.path.join(D, "parts_fixed")
RENDERS = os.path.join(D, "renders_fixed")

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


def req(method, url, data=None, ctype=None, retries=3):
    for a in range(retries):
        h = H()
        if ctype:
            h["Content-Type"] = ctype
        try:
            r = urllib.request.Request(url, data=data, headers=h, method=method)
            with urllib.request.urlopen(r, timeout=300) as resp:
                raw = resp.read()
            return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            if e.code == 401:
                refresh(); continue
            if e.code in (403, 429, 500, 502, 503) and a < retries - 1:
                time.sleep(4 * (a + 1)); continue
            raise
    raise RuntimeError("failed")


def get(url):
    return req("GET", url)


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


def trash(fid):
    req("DELETE", "https://www.googleapis.com/drive/v3/files/%s" % fid)


def rename(fid, name):
    req("PATCH", "https://www.googleapis.com/drive/v3/files/%s" % fid,
        data=json.dumps({"name": name}).encode(), ctype="application/json")


refresh()

models_new = json.load(open("/tmp/vil/models_fixed_fid.json"))
print("новая папка models: %s" % models_new, flush=True)

# --- 1. проверка готовности новых файлов ---
ok = True
for label, fid, base, ext in (("models_new", models_new, PARTS, ".fbx"),
                              ("renders_new", ID_RENDERS_NEW, RENDERS, ".png")):
    remote = {f["name"]: int(f["size"]) for f in listdir(fid)}
    local = {fn: os.path.getsize(os.path.join(base, fn))
             for fn in os.listdir(base) if fn.endswith(ext)}
    miss = [k for k in local if k not in remote]
    bad = [k for k in local if k in remote and remote[k] != local[k]]
    extra = [k for k in remote if k not in local]
    print("%s: локально %d, Drive %d, нет %d, размер %d, лишних %d"
          % (label, len(local), len(remote), len(miss), len(bad), len(extra)), flush=True)
    if miss or bad or extra or len(local) != 152:
        print("  !!! НЕ ГОТОВО, останавливаюсь", flush=True)
        ok = False
    if miss: print("  нет: %s" % miss[:5], flush=True)
    if bad: print("  размер: %s" % bad[:5], flush=True)

if not ok:
    print("СТОП: новые файлы не полностью на Drive, ничего не удаляю", flush=True)
    sys.exit(1)

if "--execute" not in sys.argv:
    print("\nПроверка пройдена. Запусти с --execute для фактической подмены.", flush=True)
    sys.exit(0)

# --- 2. удалить старое ---
for label, fid in (("старые FBX", ID_MODELS_OLD), ("старые PNG", ID_RENDERS_OLD)):
    fs = listdir(fid)
    print("удаляю %s: %d файлов" % (label, len(fs)), flush=True)
    n = 0
    for f in fs:
        try:
            trash(f["id"]); n += 1
        except Exception as e:
            print("  ОШИБКА %s: %s" % (f["name"], e), flush=True)
        if n % 50 == 0 and n:
            print("  ...%d" % n, flush=True)
    print("  удалено %d из %d" % (n, len(fs)), flush=True)

# --- 3. переименовать новые папки ---
time.sleep(3)
rename(models_new, "models")
rename(ID_RENDERS_NEW, "renders")
print("новые папки переименованы в models / renders", flush=True)

# --- 4. итоговая проверка ---
print("\n=== ИТОГ ===", flush=True)
for label, fid, base, ext in (("models", models_new, PARTS, ".fbx"),
                              ("renders", ID_RENDERS_NEW, RENDERS, ".png")):
    fs = listdir(fid)
    remote = {f["name"]: int(f["size"]) for f in fs}
    local = {fn: os.path.getsize(os.path.join(base, fn))
             for fn in os.listdir(base) if fn.endswith(ext)}
    miss = [k for k in local if k not in remote]
    bad = [k for k in local if k in remote and remote[k] != local[k]]
    print("%s: Drive %d | нет %d | размер не совпал %d"
          % (label, len(remote), len(miss), len(bad)), flush=True)

# старые папки должны быть пусты/удалены
for label, fid in (("старая models", ID_MODELS_OLD), ("старая renders", ID_RENDERS_OLD)):
    try:
        left = listdir(fid)
        print("%s: осталось %d файлов" % (label, len(left)), flush=True)
    except urllib.error.HTTPError as e:
        print("%s: недоступна (%s) — удалена" % (label, e.code), flush=True)

kids = {f["name"]: f["id"] for f in listdir(ID_DARIO)}
print("\nсодержимое папки Дарио: %s" % sorted(kids), flush=True)
print("https://drive.google.com/drive/folders/%s" % ID_DARIO, flush=True)