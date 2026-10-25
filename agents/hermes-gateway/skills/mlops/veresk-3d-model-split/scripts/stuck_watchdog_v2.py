#!/usr/bin/env python3
"""Сторож батча: отчёт ТОЛЬКО при смене состояния. Пустой stdout = тишина.

Зачем v2, а не просто «скрипт с интервалом»: версия v1 слала одно и то же
сообщение на КАЖДЫЙ запуск (`repeat: forever` + `*/3 * * * *`), даже если
состояние не изменилось. Итог — 13 часов одинаковых сообщений, которые
пользователь справедливо назвали «процесс зашёл в цикл».

Правила:
  * дедупликация по сигнатуре состояния (dead / crash / stall / done / working);
  * то же событие — не чаще SAME_ALERT_GAP;
  * обычный прогресс — не чаще REPORT_EVERY;
  * завершение — ровно один раз (finished_reported);
  * прогресс = изменился счётчик файлов, а не «процесс жив»:
    last_status у cron-задачи остаётся 'ok' даже при простое.

Проверка дедупликации:
    python3 stuck_watchdog_v2.py
    python3 stuck_watchdog_v2.py   # второй раз подряд: пусто = работает
"""
import argparse
import json
import os
import re
import subprocess
import time

DEFAULT = {
    "dir": "/opt/data/workspace/dsh_model_split/Dario",
    "log": "/tmp/vil/batch_dario2.log",
    "total": 211,
    "proc_pattern": "batch_split_render",
    "stall_sec": 1800,
    "report_every": 3600,
    "same_alert_gap": 4 * 3600,
}


def live_procs(pattern):
    r = subprocess.run(["pgrep", "-c", "-f", pattern],
                       capture_output=True, text=True)
    out = r.stdout.strip()
    return int(out) if out.isdigit() else 0


def count(dirname, ext):
    p = os.path.join(DEFAULT["dir"], dirname)
    if not os.path.isdir(p):
        return 0
    return len([f for f in os.listdir(p) if f.endswith(ext)])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", default="/tmp/vil/batch_watch2.json")
    args = ap.parse_args()

    cfg = DEFAULT
    state = {}
    if os.path.exists(args.state):
        try:
            state = json.load(open(args.state))
        except Exception:
            state = {}

    parts = count("parts", ".fbx")
    renders = count("renders", ".png")
    live = live_procs(cfg["proc_pattern"])
    now = time.time()

    txt = ""
    if os.path.exists(cfg["log"]):
        txt = open(cfg["log"], errors="replace").read()

    items = re.findall(r"^ITEM\s+(\d+)/(\d+)", txt, re.M)
    done = int(items[-1][0]) if items else 0
    finished = "ALL_DONE" in txt
    crashed = ("EXIT=" in txt and "EXIT=0" not in txt) or "Traceback" in txt

    last_change = state.get("last_change_ts", 0.0)
    if done != state.get("last_done") or parts != state.get("parts"):
        last_change = now
    idle = now - last_change

    if finished:
        sig = "done"
    elif crashed:
        sig = "crash"
    elif live == 0 and done < cfg["total"]:
        sig = "dead"
    elif idle > cfg["stall_sec"]:
        sig = "stall"
    else:
        sig = "working"

    prev_sig = state.get("sig")
    last_alert_ts = state.get("last_alert_ts", 0.0)
    last_report_ts = state.get("last_report_ts", 0.0)

    msg = None
    if sig == "done":
        if not state.get("finished_reported"):
            msg = ("✅ Батч завершён: %d/%d предметов, моделей %d, рендеров %d"
                   % (done, cfg["total"], parts, renders))
            state["finished_reported"] = True
            state["last_alert_sig"] = sig
            state["last_alert_ts"] = now
    elif sig in ("dead", "crash", "stall"):
        if sig != prev_sig or (now - last_alert_ts) > cfg["same_alert_gap"]:
            why = {
                "dead": "процесс завершился, а работа не закончена",
                "crash": "в логе ошибка",
                "stall": "нет прогресса %d мин при живом процессе" % (idle // 60),
            }[sig]
            msg = ("⚠️ %s (%d/%d).\nМоделей %d, рендеров %d.\nЛог: %s"
                   % (why, done, cfg["total"], parts, renders, cfg["log"]))
            state["last_alert_sig"] = sig
            state["last_alert_ts"] = now
    else:
        if (now - last_report_ts) > cfg["report_every"]:
            msg = ("ℹ️ Батч: %d/%d (%.0f%%), рендеров %d."
                   % (done, cfg["total"], 100.0 * done / cfg["total"], renders))
            state["last_report_ts"] = now

    state.update({"sig": sig, "last_done": done, "last_change_ts": last_change,
                  "parts": parts, "renders": renders, "live": live})
    os.makedirs(os.path.dirname(args.state) or ".", exist_ok=True)
    with open(args.state, "w") as f:
        json.dump(state, f)

    if msg:
        print(msg)


if __name__ == "__main__":
    main()