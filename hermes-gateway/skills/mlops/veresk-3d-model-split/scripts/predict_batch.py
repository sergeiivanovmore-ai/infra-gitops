#!/usr/bin/env python3
"""
Шаг 1–2 пайплайна: список FBX в папке Drive + прогноз числа частей по каждому файлу.

  python3 predict_batch.py --folder "<ссылка>" --parts 4
      -> печатает JSON со списком файлов и прогнозом (axis, parts, objects)

  python3 predict_batch.py --folder "<ссылка>" --files id1,id2 --parts 4
      -> прогноз только по выбранным файлам

Файлы кэшируются в <workdir>/_predict_cache.json (по ID файла), чтобы
повторный прогон не качал и не анализировал заново без --force.
"""

import argparse
import json
import os
import subprocess
import sys
import time

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import gdrive_ops as gd  # noqa: E402

BLENDER = "/tmp/blender-4.2.3-linux-x64/blender"
SCRIPTS = os.path.dirname(os.path.abspath(__file__))
DEFAULT_WORKDIR = "/opt/data/workspace/dsh_model_split"
CACHE_NAME = "_predict_cache.json"
# Порог зазора для режима "крупные зазоры": отбрасываем щели мелких деталей (<1% длины)
ROBUST_GAP = 0.01
ROBUST_MODE = False


def emit(stage, status, **kw):
    rec = {"stage": stage, "status": status, "ts": round(time.time(), 1)}
    rec.update(kw)
    print(json.dumps(rec, ensure_ascii=False), flush=True)


def predict_one(file_id, name, parts, axis, workdir, force=False, cache=None):
    key = "%s|%s|%s|%s" % (file_id, parts, axis, ROBUST_MODE)
    if not force and cache and key in cache:
        return cache[key]

    local_dir = os.path.join(workdir, os.path.splitext(name)[0], "input")
    os.makedirs(local_dir, exist_ok=True)
    local_fbx = os.path.join(local_dir, os.path.basename(name))

    if not os.path.exists(local_fbx) or os.path.getsize(local_fbx) == 0:
        gd.download_file(file_id, local_fbx, show_progress=False)

    gap_ratio = ROBUST_GAP if ROBUST_MODE else 0.0
    cmd = [BLENDER, "--background", "--python",
           os.path.join(SCRIPTS, "predict_parts.py"), "--",
           "--input", local_fbx, "--parts", str(parts), "--axis", axis,
           "--min-gap-ratio", str(gap_ratio)]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
    payload = None
    for line in proc.stdout.splitlines():
        if line.startswith("PREDICT_JSON "):
            payload = line[len("PREDICT_JSON "):]
    if payload is None:
        return {"file": name, "file_id": file_id, "error": "Blender не ответил",
                "detail": (proc.stdout[-800:] + proc.stderr[-800:])}
    data = json.loads(payload)
    data["file_id"] = file_id
    if cache is not None and not data.get("error"):
        cache[key] = data
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--folder", required=True)
    ap.add_argument("--parts", default="auto",
                    help="'auto' (по умолчанию) = число частей по всем естественным "
                         "зазорам; или число, например 4")
    ap.add_argument("--axis", default="auto")
    ap.add_argument("--files", default="", help="ID файлов через запятую (по умолчанию все)")
    ap.add_argument("--workdir", default=DEFAULT_WORKDIR)
    ap.add_argument("--robust", action="store_true",
                    help="игнорировать зазоры <1%% длины модели (только крупные)")
    ap.add_argument("--force", action="store_true", help="пересчитать прогноз")
    args = ap.parse_args()

    global ROBUST_MODE
    ROBUST_MODE = args.robust

    os.makedirs(args.workdir, exist_ok=True)
    cache_path = os.path.join(args.workdir, CACHE_NAME)
    cache = {}
    if os.path.exists(cache_path):
        try:
            with open(cache_path) as f:
                cache = json.load(f)
        except Exception:
            cache = {}

    folder_id = gd.resolve_folder_id(args.folder)
    emit("folder", "resolved", folder_id=folder_id, url=gd.folder_url(folder_id))

    all_files = gd.list_fbx(folder_id, recursive=True)
    emit("folder", "listed", count=len(all_files))

    if args.files.strip():
        wanted_ids = [x.strip() for x in args.files.split(",") if x.strip()]
        by_id = {f["id"]: f for f in all_files}
        missing = [i for i in wanted_ids if i not in by_id]
        targets = [by_id[i] for i in wanted_ids if i in by_id]
    elif len(all_files) <= 1:
        targets = all_files
        missing = []
    else:
        # ЗАЩИТА: не качать и не анализировать всю папку молча.
        # Сначала list_files.py -> выбор пользователя -> прогноз по выбранным.
        print("BATCH_JSON " + json.dumps(
            {"error": "Укажи --files: в папке %d файлов. Сначала покажи пользователю "
                       "список имён (list_files.py), дождись выбора, потом считай прогноз "
                       "только по выбранным — иначе скачаются все файлы подряд."
                       % len(all_files),
             "available": [{"n": i, "id": f["id"], "name": f["name"],
                            "size_mb": round(f["size"] / 1048576.0, 1)}
                           for i, f in enumerate(all_files, 1)]},
            ensure_ascii=False))
        return 2

    results = []
    for n, f in enumerate(targets, 1):
        emit("predict", "item_start", n=n, total=len(targets), file=f["name"])
        r = predict_one(f["id"], f["name"], args.parts, args.axis,
                        args.workdir, args.force, cache)
        results.append(r)
        emit("predict", "item_done", file=f["name"],
             planned_parts=r.get("planned_parts"), axis=r.get("axis"),
             objects=r.get("objects"), parts_mode=r.get("parts_mode"),
             error=r.get("error"))

    if cache:
        with open(cache_path, "w") as f:
            json.dump(cache, f, ensure_ascii=False, indent=2)

    print("BATCH_JSON " + json.dumps(
        {"folder_id": folder_id, "parts_requested": args.parts,
         "axis": args.axis, "count": len(results), "results": results},
        ensure_ascii=False))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001
        emit("fatal", "error", detail=str(e))
        sys.exit(1)