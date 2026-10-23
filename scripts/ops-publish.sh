#!/bin/bash
# Публикация файлов агента из outbox в репозиторий — байт-в-байт, без участия человека.
#
# Зачем: у агента нет шелла и нет выхода в сеть, а запись файлов через GitHub MCP
# идёт через модель и может исказить содержимое (наблюдался 18-байтный огрызок
# вместо скрипта). Зато хост ЧИТАЕТ workspace агента напрямую — это bind
# /opt/docker/hermes-sysadmin/data/workspace. Значит транспорт — файловая система,
# а не модель, и содержимое доходит точно.
#
# Поэтому агент больше не просит человека запускать patch-скрипты на хосте.
#
# Структура outbox (в workspace агента, видна хосту как каталог выше):
#   outbox/<ИМЯ-ВЕТКИ>/<путь-в-репо>  — файл, который надо закоммитить в <ИМЯ-ВЕТКИ>
#   outbox/run/<имя-скрипта>          — запустить scripts/<имя-скрипта> (скрипт
#                                       должен уже быть в main, т.е. проходить PR)
# После успеха файлы переезжают в outbox/sent/<ИМЯ-ВЕТКИ>/ и повторно не пушятся.
#
# Права, которые это даёт агенту (осознанно и ограниченно):
#   * писать в ЛЮБУЮ ветку, кроме main (мерж остаётся человеческим);
#   * запускать ЛЮБОЙ скрипт, который уже лежит в scripts/ репозитория, т.е.
#     прошедший ревью и мерж. Произвольного шелла нет: белый список — каталог.
#
# Запускается workflow .github/workflows/ops-publish.yml (расписание, вручную,
# либо пуш в ветку ops/**).
set -u

OUTBOX="/opt/docker/hermes-sysadmin/data/workspace/outbox"
LOGDIR="/opt/docker/hermes-sysadmin/data/logs"
REPO="/opt/infra-gitops"
WT="/tmp/ops-publish-wt"

mkdir -p "$LOGDIR" 2>/dev/null
# Всё, что печатаем, дублируем в лог, который агент читает локально: логи
# GitHub Actions агенту недоступны (403 даже на публичном репозитории).
exec >> "$LOGDIR/ops-publish.log" 2>&1

log() { echo "[$(date -Iseconds)] [ops-publish] $*"; }

log "старт"
[ -d "$OUTBOX" ] || { log "outbox пуст (каталога нет) — выходим"; exit 0; }

# ---------- 1. запуск скриптов, уже влитых в репозиторий ----------
if [ -d "$OUTBOX/run" ]; then
  for req in "$OUTBOX/run"/*; do
    [ -f "$req" ] || continue
    name=$(basename "$req")
    args=$(head -c 200 "$req" | tr -d '\r\n')
    case "$name" in
      */*|*..*|"") log "SKIP run: недопустимое имя '$name'"; mv -f -- "$req" "$OUTBOX/sent/" 2>/dev/null; continue ;;
    esac
    if [ ! -f "$REPO/scripts/$name" ]; then
      log "SKIP run: scripts/$name нет в клоне (нужен PR+мерж) — заявка ждёт"
      continue
    fi
    log "RUN scripts/$name $args"
    ( cd "$REPO" && bash "scripts/$name" $args ) > "$LOGDIR/ops-run-$name.log" 2>&1
    rc=$?
    echo "rc=$rc" >> "$LOGDIR/ops-run-$name.log"
    log "DONE scripts/$name rc=$rc (вывод: logs/ops-run-$name.log)"
    mkdir -p "$OUTBOX/sent/run"
    mv -f -- "$req" "$OUTBOX/sent/run/$name.$rc" 2>/dev/null || true
  done
fi

# ---------- 2. публикация файлов в ветки ----------
if [ -d "$REPO/.git" ]; then
  mkdir -p "$OUTBOX/sent"
  for bdir in "$OUTBOX"/*/; do
    [ -d "$bdir" ] || continue
    branch=$(basename "$bdir")
    case "$branch" in
      sent|run) continue ;;
      main|master|HEAD) log "SKIP ветку '$branch': писать в неё нельзя"; continue ;;
    esac

    files=$(cd "$bdir" && find . -type f | sed 's|^\./||')
    [ -n "$files" ] || continue
    count=$(printf '%s\n' "$files" | wc -l)

    rm -rf "$WT"
    if ! git -C "$REPO" worktree add -f --detach "$WT" >/dev/null 2>&1; then
      log "ERROR: не создать worktree для '$branch'"
      continue
    fi
    git -C "$WT" checkout -f -B "$branch" >/dev/null 2>&1 || true

    while IFS= read -r f; do
      mkdir -p "$WT/$(dirname "$f")"
      cp -f "$bdir/$f" "$WT/$f"
    done <<< "$files"

    git -C "$WT" add -A
    if git -C "$WT" diff --cached --quiet; then
      log "ветка $branch: содержимое уже такое же, коммит не нужен"
    else
      git -C "$WT" -c user.name="hermes-sysadmin" \
                     -c user.email="hermes-sysadmin@localhost" \
          commit -q -m "ops: публикация из outbox агента ($(date -Iseconds))"
      if git -C "$WT" push -q -f origin "HEAD:refs/heads/$branch"; then
        log "ветка $branch: опубликовано файлов: $count (force-push)"
        mkdir -p "$OUTBOX/sent/$branch"
        while IFS= read -r f; do
          mkdir -p "$OUTBOX/sent/$branch/$(dirname "$f")"
          mv -f "$bdir/$f" "$OUTBOX/sent/$branch/$f"
        done <<< "$files"
      else
        log "ERROR: push в ветку $branch не удался"
      fi
    fi
    git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  done
else
  log "WARN: $REPO не git-репозиторий — публикация пропущена"
fi

log "готово"