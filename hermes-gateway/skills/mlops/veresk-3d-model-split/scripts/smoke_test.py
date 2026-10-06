#!/usr/bin/env python3
"""
Smoke-тест пайплайна veresk-3d-model-split без обращения к Google Drive.

Прогоняет локальный FBX через весь цикл на быстрых настройках:
    predict -> split (с --select) -> render

Использовать после правки любого из скриптов пайплайна — за секунды
показывает, что экспорт изолированных частей и рендер не сломались.

Запуск:
  python3 smoke_test.py --input /path/to/model.fbx [--parts auto|4] [--select 1,3]
                       [--outdir /tmp/veresk_smoke] [--keep]

--parts по умолчанию auto: число частей считается по зазорам, как в реальном
пайплайне. Прогноз и разбиение получают одно и то же число.

Возвращает 0 если все этапы прошли, 1 иначе.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

BLENDER = "/tmp/blender-4.2.3-linux-x64/blender"
SCRIPTS = os.path.dirname(os.path.abspath(__file__))


def emit(stage, status, **kw):
    rec = {"stage": stage, "status": status, "ts": round(time.time(), 1)}
    rec.update(kw)
    print(json.dumps(rec, ensure_ascii=False), flush=True)


def run_blender(script, args, marker, timeout=3600):
    cmd = [BLENDER, "--background", "--python", os.path.join(SCRIPTS, script), "--"] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    payload = None
    for line in proc.stdout.splitlines():
        if line.startswith(marker + " "):
            payload = line[len(marker) + 1:]
    if payload is None:
        tail = (proc.stdout[-800:] + "\n---STDERR---\n" + proc.stderr[-800:])
        raise RuntimeError("%s не вернул %s (rc=%s)\n%s" % (script, marker,
                                                            proc.returncode, tail))
    return json.loads(payload)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="локальный FBX")
    ap.add_argument("--parts", default="auto",
                    help="'auto' (по умолчанию) = число частей по зазорам; или число")
    ap.add_argument("--select", default="", help="номера частей, напр. 1,3 (пусто = все)")
    ap.add_argument("--axis", default="auto")
    ap.add_argument("--outdir", default="/tmp/veresk_smoke")
    ap.add_argument("--samples", type=int, default=16, help="быстрый прогон: 16")
    ap.add_argument("--res", type=int, default=512, help="быстрый прогон: 512")
    ap.add_argument("--keep", action="store_true", help="не удалять временные файлы")
    args = ap.parse_args()

    if not os.path.exists(BLENDER):
        print("FAIL: Blender не найден: %s" % BLENDER)
        return 1
    if not os.path.exists(args.input):
        print("FAIL: FBX не найден: %s" % args.input)
        return 1

    outdir = args.outdir
    shutil.rmtree(outdir, ignore_errors=True)
    models = os.path.join(outdir, "models")
    renders = os.path.join(outdir, "renders")
    os.makedirs(models)
    os.makedirs(renders)

    try:
        # ---- 1. Прогноз ----
        emit("smoke", "predict_start", input=args.input)
        pred = run_blender("predict_parts.py",
                           ["--input", args.input, "--parts", str(args.parts),
                            "--axis", args.axis], "PREDICT_JSON")
        if pred.get("error"):
            emit("smoke", "predict_fail", detail=pred["error"])
            return 1
        emit("smoke", "predict_ok", planned_parts=pred["planned_parts"],
             axis=pred["axis"], objects=pred["objects"],
             not_enough_gaps=pred.get("not_enough_gaps"))

        available = [str(p["number"]) for p in pred["parts"]]
        if not available:
            emit("smoke", "fail", detail="Прогноз не дал ни одной части")
            return 1

        # ВАЖНО: разбиение запускаем с ЧИСЛОМ из прогноза, а не со строкой "auto".
        # Иначе прогноз и разбиение считают N двумя независимыми вызовами анализа
        # и могут разойтись — smoke-тест перестанет ловить эту расхождёнку.
        effective_parts = int(pred["planned_parts"])
        emit("smoke", "parts_resolved", requested=args.parts,
             parts_mode=pred.get("parts_mode"), effective_parts=effective_parts)

        sel = [s.strip() for s in args.select.split(",") if s.strip()] or available
        sel = [s for s in sel if s in available]
        if not sel:
            emit("smoke", "fail", detail="Нет валидных номеров для выбора", available=available)
            return 1

        # ---- 2. Разделение с выбором ----
        emit("smoke", "split_start", select=sel, parts=effective_parts)
        spl = run_blender("split_selected.py",
                          ["--input", args.input, "--out", models,
                           "--parts", str(effective_parts), "--axis", args.axis,
                           "--select", ",".join(sel)], "SPLIT_JSON")
        if spl.get("error"):
            emit("smoke", "split_fail", detail=spl["error"])
            return 1
        emit("smoke", "split_ok", exported=spl["exported"])

        # Проверка: экспортировано ровно то, что выбрали
        got = sorted(spl["exported"], key=int)
        if got != sorted(sel, key=int):
            emit("smoke", "split_mismatch", expected=sorted(sel), got=got)
            return 1

        missing_files = [n for n in sel
                         if not os.path.exists(os.path.join(models, n + ".fbx"))]
        if missing_files:
            emit("smoke", "split_files_missing", missing=missing_files)
            return 1
        empty = [n for n in sel
                 if os.path.getsize(os.path.join(models, n + ".fbx")) == 0]
        if empty:
            emit("smoke", "split_files_empty", empty=empty)
            return 1

        # ---- 3. Рендер ----
        emit("smoke", "render_start", samples=args.samples, res=args.res)
        rnd = run_blender("render_parts.py",
                          ["--models-dir", models, "--out-dir", renders,
                           "--select", ",".join(sel),
                           "--samples", str(args.samples), "--res", str(args.res)],
                          "RENDER_JSON")
        if rnd.get("error"):
            emit("smoke", "render_fail", detail=rnd["error"])
            return 1
        for r in rnd["results"]:
            emit("smoke", "render_item", part=r["part"], ok=r["ok"], error=r.get("error"))

        bad = [r["part"] for r in rnd["results"] if not r["ok"]]
        if bad:
            emit("smoke", "render_fail_parts", parts=bad)
            return 1

        # PNG должен начинаться с валидной сигнатуры
        for n in sel:
            png = os.path.join(renders, "%s_iso.png" % n)
            if not os.path.exists(png):
                emit("smoke", "png_missing", part=n)
                return 1
            with open(png, "rb") as f:
                sig = f.read(8)
            if sig != b"\x89PNG\r\n\x1a\n":
                emit("smoke", "png_corrupt", part=n, signature=repr(sig))
                return 1

        emit("smoke", "PASS", parts=sel, outdir=outdir,
             note="Google Drive не проверялся (нет обращения к сети)")
        return 0
    except Exception as e:  # noqa: BLE001
        emit("smoke", "EXCEPTION", detail=str(e))
        return 1
    finally:
        if not args.keep:
            pass  # оставляем файлы — полезно для просмотра рендеров
        else:
            emit("smoke", "kept", outdir=outdir)


if __name__ == "__main__":
    sys.exit(main())