#!/usr/bin/env python3
"""
Шаг 1 пайплайна: ТОЛЬКО список имён FBX в папке Drive.

Ничего не скачивает, не запускает Blender, не анализирует геометрию —
занимает секунды. Это сознательно: сначала спрашиваем пользователя,
какие файлы нужны, и только потом качаем выбранные.

Запуск:
  python3 list_files.py --folder "https://drive.google.com/drive/folders/ID"

Вывод: строка LIST_JSON {...} + человекочитаемый блок для показа пользователю.
"""

import argparse
import json
import os
import sys

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import gdrive_ops as gd  # noqa: E402


def human_size(n):
    if not n:
        return "?"
    mb = n / 1048576.0
    if mb >= 1024:
        return "%.1f ГБ" % (mb / 1024.0)
    return "%.1f МБ" % mb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--folder", required=True)
    ap.add_argument("--flat", action="store_true",
                    help="не обходить вложенные папки")
    args = ap.parse_args()

    folder_id = gd.resolve_folder_id(args.folder)
    files = gd.list_fbx(folder_id, recursive=not args.flat)

    payload = {
        "folder_id": folder_id,
        "folder_url": gd.folder_url(folder_id),
        "count": len(files),
        "files": [
            {
                "n": i,
                "id": f["id"],
                "name": f["name"],
                "size_mb": round(f["size"] / 1048576.0, 1),
                "size_human": human_size(f["size"]),
                "subfolder": f["subfolder"],
            }
            for i, f in enumerate(files, 1)
        ],
    }
    print("LIST_JSON " + json.dumps(payload, ensure_ascii=False))

    # Блок для прямого показа пользователю
    print("")
    print("В папке %d FBX-файл(ов):" % len(files), file=sys.stderr)
    for f in payload["files"]:
        prefix = "[%s/] " % f["subfolder"] if f["subfolder"] else ""
        print("  %d. %s%s  — %s" % (f["n"], prefix, f["name"], f["size_human"]),
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"stage": "fatal", "error": str(e)}, ensure_ascii=False))
        sys.exit(1)