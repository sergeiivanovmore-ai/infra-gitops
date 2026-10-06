#!/usr/bin/env python3
"""Расчётный учёт токенов Hermes-сессии.

Счётчик usage в локальных логах не пишется, токенизатор в системе обычно
отсутствует — считаем эвристикой по объёму символов с поправкой на кириллицу.

Использование:
    python3 measure_session_tokens.py /opt/data/sessions/session_XXX.json
    python3 measure_session_tokens.py            # последняя сессия сама
"""
import json
import os
import re
import sys
import glob

CYR_PER_TOKEN = 2.1   # кириллица жжёт токены сильнее латиницы
LAT_PER_TOKEN = 3.6


def to_text(content):
    """Свести содержимое сообщения в строку (учёт tool_use / tool_result)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for part in content:
            if isinstance(part, str):
                out.append(part)
            elif isinstance(part, dict):
                for key in ("text", "content", "output", "result"):
                    if isinstance(part.get(key), str):
                        out.append(part[key])
                if part.get("type") == "tool_use":
                    out.append(json.dumps(part.get("input", {}), ensure_ascii=False))
        return "\n".join(out)
    return json.dumps(content, ensure_ascii=False)


def tokens(text):
    """Грубая оценка числа токенов."""
    if not text:
        return 0
    cyr = len(re.findall(r"[а-яА-ЯёЁ]", text))
    return cyr / CYR_PER_TOKEN + (len(text) - cyr) / LAT_PER_TOKEN


def analyse(path):
    with open(path) as f:
        data = json.load(f)

    sp = tokens(to_text(data.get("system_prompt", "")))
    tools = tokens(json.dumps(data.get("tools", {}), ensure_ascii=False))
    base = sp + tools

    msgs = data.get("messages", [])
    cum = base
    total_in = 0
    total_out = 0
    calls = 0
    unique_msg = 0
    per_call = []

    for m in msgs:
        role = m.get("role", "?")
        t = tokens(to_text(m.get("content", "")))
        if role == "assistant":
            calls += 1
            total_in += cum      # весь накопленный контекст уходит на этот вызов
            total_out += t
            per_call.append(cum)
            cum += t             # ответ добавляется в историю
        else:
            unique_msg += t
            cum += t

    unique_total = base + unique_msg
    return {
        "file": path,
        "model": data.get("model"),
        "messages": len(msgs),
        "calls": calls,
        "sp_tokens": sp,
        "tools_tokens": tools,
        "base_tokens": base,
        "unique_total": unique_total,
        "input": total_in,
        "output": total_out,
        "total": total_in + total_out,
        "amplification": (total_in + total_out) / unique_total if unique_total else 0,
        "ctx_first": per_call[0] if per_call else 0,
        "ctx_max": max(per_call) if per_call else 0,
    }


def main():
    if len(sys.argv) > 1:
        path = sys.argv[1]
    else:
        found = sorted(glob.glob("/opt/data/sessions/session_*.json"),
                       key=os.path.getmtime)
        if not found:
            print("логи сессий не найдены в /opt/data/sessions/")
            return 1
        path = found[-1]

    r = analyse(path)

    print("=" * 62)
    print("СЕССИЯ: %s" % os.path.basename(path))
    print("модель: %s   сообщений: %d" % (r["model"], r["messages"]))
    print("=" * 62)
    print("\nБАЗА НА КАЖДЫЙ ВЫЗОВ (пересылается всегда)")
    print("  system prompt       %9d" % r["sp_tokens"])
    print("  схемы инструментов %9d" % r["tools_tokens"])
    print("  база               %9d" % r["base_tokens"])
    print("\nУНИКАЛЬНЫЙ ОБЪЁМ (написан один раз)")
    print("  сообщения + выводы %9d" % (r["unique_total"] - r["base_tokens"]))
    print("  итого              %9d" % r["unique_total"])
    print("\nПЕРЕСЛАНО (агентный цикл, БЕЗ КЭША)")
    print("  вызовов LLM        %9d" % r["calls"])
    print("  ввод               %9d" % r["input"])
    print("  вывод              %9d" % r["output"])
    print("  ИТОГО              %9d" % r["total"])
    print("\n  кратность пересылки: %.1fx" % r["amplification"])
    print("  контекст: первый вызов %.0f -> максимум %.0f"
          % (r["ctx_first"], r["ctx_max"]))
    if r["tools_tokens"] and r["calls"] and r["input"]:
        share = r["tools_tokens"] * r["calls"] / r["input"] * 100
        print("  доля схем инструментов во вводе: %.0f%%" % share)
    print("\nВАЖНО: цифры БЕЗ учёта кэша промптов. Кэшированный префикс")
    print("       (system prompt + схемы) тарифицируется в 10-25 раза дешевле.")
    print("\nTOKENS_JSON " + json.dumps({
        "file": os.path.basename(path),
        "model": r["model"],
        "calls": r["calls"],
        "input": int(r["input"]),
        "output": int(r["output"]),
        "total": int(r["total"]),
        "unique_total": int(r["unique_total"]),
        "amplification": round(r["amplification"], 1),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())