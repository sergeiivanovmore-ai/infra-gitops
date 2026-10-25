#!/usr/bin/env python3
"""
Оркестратор: скачать FBX -> разбить на выбранные части -> отрендерить ->
загрузить на Google Drive в <исходная_папка>/<имя_файла>/{models,renders}.

Один файл за раз (пайплайн вызывается последовательно для каждого файла).
Прогресс печатается построчно в stdout как JSON-строки со статусами —
их можно отправлять пользователю по мере появления.

Запуск:
  python3 process_file.py \
      --folder "https://drive.google.com/drive/folders/ID" \
      --file-id FILE_ID \
      --file-name "Шкаф.fbx" \
      --parts 4 \
      --select 1,3 \
      [--workdir /path] [--mapping a:0,b:1] [--samples 128] [--res 1024]

Опции --select all / пусто -> берутся все части.
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


def emit(stage, status, **kw):
    """Напечатать строку статуса (stdout) — её перехватывает агент."""
    rec = {"stage": stage, "status": status, "ts": round(time.time(), 1)}
    rec.update(kw)
    print(json.dumps(rec, ensure_ascii=False), flush=True)


def run_blender(script, args, marker):
    """Запустить скрипт в Blender и распарсить JSON-строку маркера."""
    cmd = [BLENDER, "--background", "--python", os.path.join(SCRIPTS, script), "--"] + args
    emit("blender", "start", script=script, cmd=" ".join(cmd[1:]))
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=7200)
    payload = None
    for line in proc.stdout.splitlines():
        if line.startswith(marker + " "):
            payload = line[len(marker) + 1:]
    if payload is None:
        tail = (proc.stdout[-1500:] + "\n---STDERR---\n" + proc.stderr[-1500:])
        emit("blender", "error", script=script, detail=tail)
        raise RuntimeError("Blender не вернул %s (rc=%s)" % (marker, proc.returncode))
    try:
        return json.loads(payload)
    except json.JSONDecodeError as e:
        raise RuntimeError("Невалидный JSON от %s: %s" % (script, e))


def parse_selection(sel, available):
    """'all' / '' -> все; '1,3,5' -> отфильтровать по наличию."""
    if not sel or sel.strip().lower() in ("all", "*", "все"):
        return available, []
    wanted = [s.strip() for s in sel.split(",") if s.strip()]
    return [w for w in wanted if w in available], [w for w in wanted if w not in available]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--folder", required=True, help="ссылка или ID папки Google Drive")
    ap.add_argument("--file-id", required=True, help="ID FBX-файла в Drive")
    ap.add_argument("--file-name", required=True, help="имя FBX-файла")
    ap.add_argument("--parts", default="",
                    help="число частей. Если НЕ задано — скрипт только покажет "
                         "прогноз и остановится, дождавшись выбора пользователя. "
                         "'auto' = по всем естественным зазорам")
    ap.add_argument("--select", default="", help="номера частей: 1,3,5 или all")
    ap.add_argument("--axis", default="auto")
    ap.add_argument("--mapping", default="", help="a:0,b:1+2 — группировка кластеров")
    ap.add_argument("--workdir", default=DEFAULT_WORKDIR)
    ap.add_argument("--samples", type=int, default=128)
    ap.add_argument("--res", type=int, default=1024)
    ap.add_argument("--skip-upload", action="store_true")
    args = ap.parse_args()

    base = os.path.splitext(os.path.basename(args.file_name))[0]
    local_dir = os.path.join(args.workdir, base)
    models_dir = os.path.join(local_dir, "models")
    renders_dir = os.path.join(local_dir, "renders")
    input_dir = os.path.join(local_dir, "input")
    os.makedirs(models_dir, exist_ok=True)
    os.makedirs(renders_dir, exist_ok=True)
    os.makedirs(input_dir, exist_ok=True)

    emit("start", "begin", file=args.file_name, dir=local_dir)

    # ---------- 1. Скачать исходник ----------
    emit("download", "start", file=args.file_name)
    local_fbx = os.path.join(input_dir, os.path.basename(args.file_name))
    if not os.path.exists(local_fbx) or os.path.getsize(local_fbx) == 0:
        gd.download_file(args.file_id, local_fbx, show_progress=True)
    emit("download", "done", path=local_fbx, size_mb=round(
        os.path.getsize(local_fbx) / 1048576.0, 2))

    # ---------- 2. Решение по числу частей ----------
    # Если число частей не задано — НИЧЕГО не делаем молча.
    # Показываем прогноз и просим пользователя выбрать.
    if str(args.parts).strip().lower() in ("auto", "", "?"):
        pred_ro = run_blender("predict_parts.py",
                              ["--input", local_fbx, "--parts", "auto",
                               "--axis", args.axis],
                              "PREDICT_JSON")
        if pred_ro.get("error"):
            emit("predict", "error", detail=pred_ro["error"])
            return 1
        emit("await_choice", "paused",
             detail="Число частей не задано — нужен выбор пользователя.",
             axis=pred_ro["axis"], objects=pred_ro["objects"],
             planned_parts=pred_ro["planned_parts"],
             planned_parts_robust=pred_ro["planned_parts_robust"],
             gaps_total=pred_ro.get("gaps_total"),
             gaps_robust=pred_ro.get("gaps_robust"),
             parts=pred_ro["parts"], warnings=pred_ro.get("warnings", []))
        return 3
    # ВАЖНО: если parts=auto, прогноз сам считает N по зазорам. Дальше разбиение
    # запускается с ЭТИМ числом, а не с "auto" — иначе два независимых вызова
    # анализа могут разойтись и номера частей не совпадут с прогнозом.
    pred = run_blender("predict_parts.py",
                       ["--input", local_fbx, "--parts", str(args.parts),
                        "--axis", args.axis],
                       "PREDICT_JSON")
    if pred.get("error"):
        emit("predict", "error", detail=pred["error"])
        return 1

    effective_parts = int(pred["planned_parts"])
    emit("predict", "done", planned_parts=effective_parts, axis=pred["axis"],
         objects=pred["objects"], parts_mode=pred.get("parts_mode"),
         gaps_usable=pred.get("gaps_usable"),
         planned_parts_robust=pred.get("planned_parts_robust"))
    for w in pred.get("warnings", []) or []:
        emit("predict", "warning", detail=w)

    available = [str(p["number"]) for p in pred["parts"]]
    selected, missing = parse_selection(args.select, available)
    if missing:
        emit("select", "warning", missing=missing, available=available)
    if not selected:
        emit("select", "error", detail="Не выбрано ни одной части", available=available)
        return 1
    emit("select", "done", selected=selected, available=available)

    # ---------- 3. Разделение (с уже вычисленным числом частей) ----------
    emit("split", "start", selected=selected, parts=effective_parts)
    spl = run_blender("split_selected.py",
                      ["--input", local_fbx, "--out", models_dir,
                       "--parts", str(effective_parts), "--axis", args.axis,
                       "--select", ",".join(selected)]
                      + (["--mapping", args.mapping] if args.mapping else []),
                      "SPLIT_JSON")
    if spl.get("error"):
        emit("split", "error", detail=spl["error"])
        return 1
    if spl.get("exported") != selected:
        emit("split", "warning",
             detail="Экспортировано %s, а запрошено %s — сверь нумерацию"
                    % (spl.get("exported"), selected))
    emit("split", "done", exported=spl["exported"])

    # ---------- 4. Рендер ----------
    emit("render", "start", samples=args.samples, res=args.res)
    rnd = run_blender("render_parts.py",
                      ["--models-dir", models_dir, "--out-dir", renders_dir,
                       "--select", ",".join(selected),
                       "--samples", str(args.samples), "--res", str(args.res)],
                      "RENDER_JSON")
    if rnd.get("error"):
        emit("render", "error", detail=rnd["error"])
        return 1
    for r in rnd["results"]:
        emit("render", "item", part=r["part"], ok=r["ok"], error=r.get("error"))
    emit("render", "done", count=rnd["count"])

    # ---------- 5. Загрузка на Drive ----------
    if args.skip_upload:
        emit("upload", "skipped")
        emit("done", "ok", models_dir=models_dir, renders_dir=renders_dir)
        return 0

    parent_id = gd.resolve_folder_id(args.folder)
    emit("upload", "start", parent=parent_id)

    root_id = gd.find_or_create_folder(parent_id, base)
    models_id = gd.find_or_create_folder(root_id, "models")
    renders_id = gd.find_or_create_folder(root_id, "renders")
    emit("upload", "folders", root=gd.folder_url(root_id),
         models=gd.folder_url(models_id), renders=gd.folder_url(renders_id))

    uploaded = {"models": [], "renders": []}
    for d, target, key in ((models_dir, models_id, "models"),
                           (renders_dir, renders_id, "renders")):
        for fn in sorted(os.listdir(d)):
            if fn.startswith(".") or fn == "groups.json" or fn == "split_manifest.json":
                continue
            if not fn.lower().endswith((".fbx", ".png")):
                continue
            fid = gd.upload_file(os.path.join(d, fn), fn, target)
            uploaded[key].append({"name": fn, "id": fid, "url": gd.file_url(fid)})
            emit("upload", "item", kind=key, name=fn, id=fid)

    emit("upload", "done", counts={"models": len(uploaded["models"]),
                                   "renders": len(uploaded["renders"])})
    emit("done", "ok", folder_url=gd.folder_url(root_id),
         models=uploaded["models"], renders=uploaded["renders"],
         local_dir=local_dir)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001
        emit("fatal", "error", detail=str(e))
        sys.exit(1)