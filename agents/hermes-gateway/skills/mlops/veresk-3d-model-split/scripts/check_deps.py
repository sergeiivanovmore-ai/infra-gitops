#!/usr/bin/env python3
"""
Проверка зависимостей для skill 'veresk-3d-model-split'
"""

import sys
import os
import json
import subprocess

def check_blender():
    blender_path = "/tmp/blender-4.2.3-linux-x64/blender"
    if os.path.exists(blender_path):
        try:
            result = subprocess.run([blender_path, "--version"], 
                                  capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                print(f"✓ Blender доступен: {result.stdout.strip()}")
                return True
        except Exception as e:
            print(f"✗ Blender недоступен: {e}")
    else:
        print(f"✗ Blender не найден по пути: {blender_path}")
    return False

def check_token():
    token_paths = ["~/.hermes/google_token.json", "/opt/data/google_token.json"]
    for path in token_paths:
        expanded = os.path.expanduser(path)
        if os.path.exists(expanded):
            try:
                with open(expanded) as f:
                    data = json.load(f)
                if 'access_token' in data and 'refresh_token' in data:
                    print(f"✓ Google токен найден: {expanded}")
                    return True
            except Exception as e:
                print(f"✗ Ошибка чтения токена {expanded}: {e}")
    print("✗ Google токен не найден")
    return False

def check_python_deps():
    try:
        import urllib.request
        import json
        import math
        print("✓ Python зависимости доступны (urllib, json, math)")
        return True
    except ImportError as e:
        print(f"✗ Отсутствуют Python зависимости: {e}")
        return False

if __name__ == "__main__":
    print("Проверка зависимостей для skill 'veresk-3d-model-split'")
    print("=" * 60)
    
    checks = [
        check_blender(),
        check_token(), 
        check_python_deps()
    ]
    
    if all(checks):
        print("\n✓ Все зависимости доступны - skill готов к использованию")
        sys.exit(0)
    else:
        print("\n✗ Некоторые зависимости отсутствуют")
        sys.exit(1)