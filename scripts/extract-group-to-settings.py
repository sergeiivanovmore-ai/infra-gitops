#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Извлекает группу настроек из хостового config.yaml агента в settings-файл.

Зачем. Скрипт apply-agent-settings.sh применяет группу ЦЕЛИКОМ: то, что лежит в
agents/<агент>/settings/<группа>.yaml, заменяет одноимённый блок в конфиге
агента. Если переносить группу руками по памяти, легко потерять ключи, которые
забудешь перечислить. Поэтому группа не переносится вручную, а извлекается из
фактического конфига как есть.

Каталог данных агента берётся из ключа config: в agents/<агент>/models.yaml —
не угадывается по имени, потому что у hermes-gateway каталог называется
/opt/docker/hermes/data, без суффикса с именем агента.

Секреты. Инструмент намеренно отказывается писать файл, если внутри группы есть
похожее на литеральный секрет значение (токен, пароль, ключ) вместо
плейсхолдера ${ИМЯ}. Такой файл нельзя коммитить, а молчаливая маскировка
привела бы к тому, что агент после применения потерял бы доступ.

Использование:
    # посмотреть, что будет (ничего не пишет)
    scripts/extract-group-to-settings.py hermes-sysadmin approvals

    # записать файл в репозиторий
    scripts/extract-group-to-settings.py hermes-sysadmin approvals --write

    # список групп, доступных для переноса
    scripts/extract-group-to-settings.py hermes-sysadmin --list
"""

import os
import re
import sys

REPO_DIR = os.environ.get("REPO_DIR", "/opt/infra-gitops")

HEADER = """# Этот файл — источник истины для группы {group} агента {agent}
# Применяется скриптом scripts/apply-agent-settings.sh из публикатора
# Меняйте только через PR
# Откат — верните прежнее содержимое этого файла
#
# ВНИМАНИЕ: применение заменяет группу целиком, поэтому здесь должны быть
# перечислены ВСЕ ключи группы. Файл получен извлечением из хостового
# config.yaml, вручную ключи не добавлялись.
"""

# Что считаем литеральным секретом.
#
# Судить по имени ключа нельзя: ключи вроде redact_secrets или secrets_in_logs
# секретов не содержат, а значение у них булево. Поэтому решают две вещи:
# явный признак (Bearer <не плейсхолдер>) и форма значения. Значение считаем
# секретом, если у него есть признаки токена — длинное, без пробелов, со
# смешением букв и цифр или в hex/base64-подобном виде.
SECRET_PATTERNS = [
    (re.compile(r"(?i)\bbearer\s+(?!\$\{)\S+"), "токен авторизации"),
]

# Ключ, значения которого почти всегда секрет (token, password, api_key...).
SECRET_KEY = re.compile(
    r"(?i)^\s*[\w.\-]*(?:token|password|passwd|secret|api_?key)[\w.\-]*\s*:")

# Значение заведомо не секрет, как бы ни назывался ключ.
NOT_SECRET_VALUE = re.compile(
    r"(?i)^(?:\$\{|null$|none$|~$|true$|false$|yes$|no$|on$|off$|<|\*+$)")

# Форма токена: длинная строка без пробелов из разрешённых символов.
TOKEN_SHAPE = re.compile(r"^[A-Za-z0-9_\-./+=]{16,}$")
# И в ней есть и цифры, и буквы — иначе это просто длинное слово.
MIXED = re.compile(r"(?=.*[0-9])(?=.*[A-Za-z])")

# Узнаваемые префиксы токенов популярных сервисов: длину такие значения могут
# иметь любую, поэтому проверяются отдельно от TOKEN_SHAPE.
KNOWN_TOKEN = re.compile(
    r"(?i)\b(?:sk|pk|rk|ghp|gho|ghs|ghr|github_pat|xox[baprs]|AKIA|AIza)"
    r"[_\-][A-Za-z0-9_\-]{8,}")
# JWT: три сегмента base64, разделённые точками.
JWT_SHAPE = re.compile(r"\beyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}")


def fail(msg):
    sys.stderr.write("ОСТАНОВ: %s\n" % msg)
    sys.exit(1)


def data_dir(agent):
    """Каталог данных агента из ключа config: в agents/<агент>/models.yaml."""
    path = os.path.join(REPO_DIR, "agents", agent, "models.yaml")
    if not os.path.isfile(path):
        fail("нет %s — сначала заведите там config: с каталогом данных" % path)
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"^config:\s*(\S+)\s*$", line)
            if m:
                val = m.group(1).rstrip("/")
                # В models.yaml ключ config: указывает прямо на файл конфига
                # (например /opt/docker/hermes/data/config.yaml), но встречается
                # и каталог. Приводим к каталогу в обоих случаях.
                if val.endswith((".yaml", ".yml")):
                    return os.path.dirname(val)
                return val
    fail("в %s нет ключа config: с каталогом данных" % path)


def top_level_groups(lines):
    return [l[:-1] for l in lines
            if l and not l.startswith((" ", "#", "-")) and l.endswith(":")]


def extract(lines, group):
    """Возвращает строки группы group целиком, с вложенностью и комментариями."""
    start = None
    for i, l in enumerate(lines):
        if l == group + ":":
            start = i
            break
    if start is None:
        fail("группы %s нет в конфиге" % group)
    out = [lines[start]]
    for l in lines[start + 1:]:
        # Баннер раздела завершает группу. Он начинается с решётки, поэтому
        # без этой проверки сбор продолжается и в файл настроек уезжает
        # хвост следующего раздела вместе с его заголовком.
        if re.match(r"^# ={10,}", l):
            break
        if l and not l.startswith((" ", "#")):
            break
        out.append(l)
    return out


def find_secrets(body):
    """Ищет литеральные секреты в строках группы.

    Возвращает (номер строки, что найдено, безопасное описание). Само значение
    в описание НЕ попадает: сообщение об отказе уходит в stderr, то есть в лог
    терминала и в CI, и печатать туда секрет нельзя — иначе инструмент,
    созданный не допускать секреты в репозиторий, сольёт их в логи.

    Строки комментариев пропускаются: русское «пароль от дашборда» в пояснении
    секретом не является. Хвостовые комментарии после значения отрезаются.
    """
    bad = []
    for n, raw in enumerate(body, 1):
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue

        m = re.match(r"^\s*([\w.\-]+)\s*:\s*(.*)$", line)
        key = m.group(1) if m else line.strip().split(":")[0][:40]
        val = m.group(2).strip().strip("\"'") if m else ""
        where = "%s: <скрыто, %d символов>" % (key, len(val)) if val else key

        hit = None
        for rx, what in SECRET_PATTERNS:
            if rx.search(line):
                hit = what
                break
        if not hit and (KNOWN_TOKEN.search(line) or JWT_SHAPE.search(line)):
            hit = "значение похоже на токен сервиса"
        if hit:
            bad.append((n, hit, where))
            continue

        if not m or not val or NOT_SECRET_VALUE.match(val):
            continue

        if SECRET_KEY.match(line) and len(val) >= 12:
            bad.append((n, "значение при ключе с secret/token/password", where))
            continue
        if len(val) >= 24 and TOKEN_SHAPE.match(val) and MIXED.search(val):
            bad.append((n, "значение похоже на токен", where))
    return bad


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    write = "--write" in sys.argv
    if not args:
        fail("укажите агента, затем группу (или --list)")

    agent = args[0]
    ddir = data_dir(agent)
    cfg = os.path.join(ddir, "config.yaml")
    if not os.path.isfile(cfg):
        fail("нет конфига %s" % cfg)
    with open(cfg, "r", encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    if "--list" in sys.argv:
        print("каталог данных: %s" % ddir)
        print("группы (%d):" % len(top_level_groups(lines)))
        for g in top_level_groups(lines):
            print("  %s" % g)
        return

    if len(args) < 2:
        fail("укажите группу")
    group = args[1]
    body = extract(lines, group)

    # Секреты проверяем первыми: незачем показывать красивый текст, если его
    # всё равно нельзя коммитить.
    if bad := find_secrets(body):
        sys.stderr.write("В группе %s найдены значения, похожие на литеральные секреты:\n" % group)
        for n, what, frag in bad:
            sys.stderr.write("  строка %d (%s): %s\n" % (n, what, frag))
        sys.stderr.write(
            "\nФайл не записан. Замените значения на ${ИМЯ_ПЕРЕМЕННОЙ}, положите\n"
            "значение в .env агента и повторите. Секреты в репозиторий не попадают.\n")
        sys.exit(2)

    out = HEADER.format(group=group, agent=agent) + "\n" + "\n".join(body) + "\n"
    dst = os.path.join(REPO_DIR, "agents", agent, "settings", group + ".yaml")

    if not write:
        print("каталог данных: %s" % ddir)
        print("источник:       %s" % cfg)
        print("назначение:     %s" % dst)
        print("строк в группе: %d" % len(body))
        print("--- содержимое будущего файла ---")
        print(out)
        print("--- (ничего не записано, добавьте --write) ---")
        return

    if os.path.exists(dst):
        fail("%s уже существует — сначала посмотрите, что там, и решите, "
             "нужно ли перезаписывать" % dst)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(out)
    print("записано: %s (%d строк)" % (dst, len(body)))
    print("дальше: git add/commit и PR. Не применяйте без ревью — группа "
          "заменяется целиком.")


if __name__ == "__main__":
    main()
