"""Проверка состояния папок Dario на Drive (ничего не меняет)."""
import json, urllib.request, urllib.parse, urllib.error

TOKEN_PATH = "/opt/data/google_token.json"
ROOT = "1R2vT_klw3YhYQFVT7ZgGNQqbE0Y9xkZL"  # кандидат — проверим
KNOWN = {
    "models": "1DjAkrZwpZQ01peI8zyYr-_U-I5P9_9tj",
    "renders": "1KsdoB4nnl5zrCw-zADkW1jfBcRdGaN6i",
}

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


def info(fid):
    return get("https://www.googleapis.com/drive/v3/files/%s?fields=id,name,mimeType,size,parents,trashed" % fid)


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


refresh()

print("=== известные папки ===")
for label, fid in KNOWN.items():
    try:
        i = info(fid)
        print("%-8s %s | %s | size=%s" % (label, fid, i.get("name"), i.get("size")))
    except urllib.error.HTTPError as e:
        print("%-8s %s | ОШИБКА %s" % (label, fid, e.code))
        continue
    fs = listdir(fid)
    pngs = [f for f in fs if f["name"].endswith(".png")]
    fbxs = [f for f in fs if f["name"].endswith(".fbx")]
    print("         файлов: %d (png %d, fbx %d)" % (len(fs), len(pngs), len(fbxs)))
    nums = sorted(int(f["name"].split(".")[0]) for f in pngs + fbxs if f["name"].split(".")[0].isdigit())
    if nums:
        print("         нумерация: %d..%d" % (min(nums), max(nums)))

print("\n=== поиск папки Dario ===")
q = urllib.parse.quote("name contains 'Dario' and mimeType='application/vnd.google-apps.folder' and trashed=false")
j = get("https://www.googleapis.com/drive/v3/files?q=%s&fields=files(id,name,parents)" % q)
for f in j.get("files", []):
    print("  %s | %s" % (f["id"], f["name"]))
if not j.get("files"):
    print("  не найдено")