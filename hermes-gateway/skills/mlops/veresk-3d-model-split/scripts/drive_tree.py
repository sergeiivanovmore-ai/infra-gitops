#!/usr/bin/env python3
"""Разрешить ID папки Drive в человеческий путь и показать дерево.

Отвечает на вопросы, которые иначе порождают ложные выводы:
  * куда на самом деле указывает захардкоженный ID
  * «в папке нет файлов» — где они на самом деле
  * есть ли дубликаты / остатки прошлых загрузок

Использование:
    python3 drive_tree.py                       # дерево 3dmodels (по умолчанию)
    python3 drive_tree.py --root <FOLDER_ID>    # дерево произвольной папки
    python3 drive_tree.py --find "Дарио"        # найти папки по имени + их пути
    python3 drive_tree.py --check models 1.fbx 211.fbx   # сверка наличия имён
"""
import argparse
import json
import os
import urllib.parse
import urllib.request

TOKEN_PATH = os.environ.get("DRIVE_TOKEN", "/opt/data/google_token.json")
FOLDER_MIME = "application/vnd.google-apps.folder"
DEFAULT_ROOT = "1B5IG-mIHgJdqUXqxANzfEDzXx0Z8pzbY"   # 3dmodels


def load_token():
    with open(TOKEN_PATH) as f:
        return json.load(f)


def make_headers(tok):
    return {"Authorization": "Bearer " + tok["access_token"]}


def refresh(tok):
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": tok["refresh_token"],
        "client_id": tok["client_id"],
        "client_secret": tok["client_secret"],
    }).encode()
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token", data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST")
    tok["access_token"] = json.load(urllib.request.urlopen(req))["access_token"]
    with open(TOKEN_PATH, "w") as f:
        json.dump(tok, f, indent=2)


def query(tok, q, fields="files(id,name,mimeType,size,parents)"):
    out, page = [], None
    while True:
        url = ("https://www.googleapis.com/drive/v3/files?q=%s&fields=%s&pageSize=1000"
               % (urllib.parse.quote(q), fields))
        if page:
            url += "&pageToken=" + page
        req = urllib.request.Request(url, headers=make_headers(tok), method="GET")
        j = json.load(urllib.request.urlopen(req))
        out += j.get("files", [])
        page = j.get("nextPageToken")
        if not page:
            return out


def children(tok, fid):
    return query(tok, "'%s' in parents and trashed=false" % fid)


def get_meta(tok, fid):
    req = urllib.request.Request(
        "https://www.googleapis.com/drive/v3/files/%s?fields=id,name,mimeType,parents" % fid,
        headers=make_headers(tok), method="GET")
    return json.load(urllib.request.urlopen(req))


def human_path(tok, fid, depth=8):
    """Полный путь «Мой диск / 3dmodels / Дарио / models».

    Единственный надёжный способ понять, что такое ID: идти по parents[],
    а не доверять комментарию в коде.
    """
    parts, cur, seen = [], fid, set()
    for _ in range(depth):
        if cur in seen:
            parts.append("...")
            break
        seen.add(cur)
        try:
            f = get_meta(tok, cur)
        except Exception:
            parts.append("<?%s>" % cur)
            break
        parts.append(f["name"])
        par = f.get("parents")
        if not par:
            break
        cur = par[0]
    return " / ".join(reversed(parts))


def show_tree(tok, fid, label, indent=0, max_depth=3):
    files = children(tok, fid)
    dirs = [f for f in files if f["mimeType"] == FOLDER_MIME]
    plain = [f for f in files if f["mimeType"] != FOLDER_MIME]
    pad = "  " * indent
    print("%s%s  — всего %d (папок %d, файлов %d)"
          % (pad, label, len(files), len(dirs), len(plain)))
    if plain:
        for f in sorted(plain, key=lambda z: z["name"])[:5]:
            print("%s   FILE %-26s %s" % (pad, f["name"], f.get("size", "-")))
        if len(plain) > 5:
            print("%s   ... ещё %d файлов" % (pad, len(plain) - 5))
    if indent < max_depth:
        for d in sorted(dirs, key=lambda z: z["name"]):
            show_tree(tok, d["id"], d["name"], indent + 1, max_depth)
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--find")
    ap.add_argument("--check", nargs="*", metavar="NAME")
    ap.add_argument("--depth", type=int, default=3)
    args = ap.parse_args()

    tok = load_token()
    refresh(tok)

    if args.find:
        print("=== Папки с именем, содержащим %r ===" % args.find)
        found = query(tok, "name contains '%s' and mimeType='%s'" % (args.find, FOLDER_MIME))
        for f in found:
            print("\n  id=%s" % f["id"])
            print("  путь: %s" % human_path(tok, f["id"]))
            show_tree(tok, f["id"], "содержимое", max_depth=args.depth)
        if not found:
            print("  не найдено")
        return

    if args.check:
        target = args.check[0]
        names = set(args.check[1:])
        files = children(tok, target)
        have = {f["name"] for f in files}
        print("в папке %s: %d файлов" % (target, len(files)))
        missing = sorted(names - have)
        print("проверяем %d имён, отсутствуют: %d" % (len(names), len(missing)))
        for n in missing[:20]:
            print("   НЕТ: %s" % n)
        return

    print("=== %s ===" % human_path(tok, args.root))
    show_tree(tok, args.root, os.path.basename(human_path(tok, args.root)),
              max_depth=args.depth)


if __name__ == "__main__":
    main()