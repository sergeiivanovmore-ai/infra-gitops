#!/bin/bash
# Публикация файлов агента из outbox в репозиторий — байт-в-байт, без модели.
#
# ЗАЧЕМ: у агента нет шелла и выхода в сеть, а запись через GitHub MCP идёт
# аргументом инструмента (контент набирает модель). Хост же ЧИТАЕТ workspace
# агента напрямую (bind /opt/docker/hermes-sysadmin/data/workspace), поэтому
# транспорт — файлы, содержимое не проходит через модель.
#
# РАЗДЕЛЕНИЕ КАНАЛОВ (после второго ревью):
#   * автоматический путь (этот скрипт) несёт только КОНТЕНТ (docs/) и запуск
#     уже влитых скриптов. Каталог scripts/ здесь ЗАПРЕЩЁН: иначе агент мог бы
#     ревьюируемым PR дописать себе «одобренный» скрипт и тут же его выполнить.
#     Правки того, что исполняется, идут только через отдельный, заметный канал —
#     ручной PR по GitHub MCP, с вашим ревью и мержем;
#   * исполнение: запускается только то, что лежит в main, без аргументов, то
#     есть в режиме плана.
#
# ОГРАНИЧЕНИЯ, ЗАШИТЫЕ В КОД:
#   1) ветки только с префиксом agent/; main/master/HEAD запрещены жёстко;
#   2) ветка ПРОДОЛЖАЕТСЯ от своего текущего состояния (fetch + checkout от
#      FETCH_HEAD), а для новой ветки база — свежий origin/main. Иначе каждый
#      следующий выпуск собирался бы от main и молча затирал прежние файлы;
#   3) пуш: для новой ветки — создание, для существующей — только
#      --force-with-lease, прибитый к SHA, наблюдённому ДО работы, и только
#      поверх ветки, вершину которой создал сам публикатор;
#   4) пути: белый список ALLOWED_PATHS, чёрный список BLOCKED_PATHS, проверка
#      ДО копирования, один плохой файл отклоняет всю ветку (fail closed);
#   5) симлинки и любые не-обычные файлы отклоняются;
#   6) режим применения (--yes) включается только именем скрипта, переданным
#      человеком через ручной workflow_dispatch (OPS_APPROVE). Инструмента
#      запуска workflow у агента нет — подделать нельзя;
#   7) запуск скрипта под timeout, свой лог ротируется по размеру.
#
# ВАЖНО О ГРАНИЦАХ: проверка автора вершины (в п.3) — это SAFETY, то есть защита
# от собственной логической ошибки публикатора, а не security-граница: email
# автора подделывается, а кто может пушить в agent/*, у того и так есть права.
# Настоящая защита — ревью PR, CODEOWNERS и ruleset на main.
#
# Структура outbox (в workspace агента):
#   outbox/agent/<тема>/<путь-в-репо>  — файл для публикации в ветку agent/<тема>
#   outbox/run/<имя-скрипта>           — запустить scripts/<имя-скрипта> из main
# После успеха файлы переезжают в outbox/sent/... (хранятся 14 дней).
set -u

OUTBOX="/opt/docker/hermes-sysadmin/data/workspace/outbox"
LOGDIR="/opt/docker/hermes-sysadmin/data/logs"
LOG="$LOGDIR/ops-publish.log"
REPO="/opt/infra-gitops"
WT="/tmp/ops-publish-wt"

BRANCH_PREFIX="agent/"
FORBIDDEN_BRANCHES="main master HEAD"
ALLOWED_PATHS="docs/"
BLOCKED_PATHS="scripts/ .github/ CODEOWNERS .gitignore .gitattributes Dockerfile docker-compose .env secrets/ .git/"
SIGNER_NAME="hermes-sysadmin"
SIGNER_EMAIL="hermes-sysadmin@localhost"
RUN_TIMEOUT=600
LOG_MAX=5242880
SENT_DAYS=14

OPS_APPROVE="${OPS_APPROVE:-}"

mkdir -p "$LOGDIR" 2>/dev/null
# Ротация: собственный лог не должен расти бесконечно.
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ]; then
  mv -f "$LOG" "$LOG.1" 2>/dev/null
fi
# Дублируем вывод в лог, который агент читает локально: логи GitHub Actions
# агенту недоступны (403 даже на публичном репозитории).
exec >> "$LOG" 2>&1

log() { echo "[$(date -Iseconds)] [ops-publish] $*"; }

# Проверка пути: белый список каталогов, чёрный список, никаких .. .
path_ok() {
  local f="$1" pre
  case "$f" in
    /*|*..*|"") return 1 ;;
  esac
  for pre in $BLOCKED_PATHS; do
    case "$f" in "$pre"*) return 1 ;; esac
  done
  for pre in $ALLOWED_PATHS; do
    case "$f" in "$pre"*) return 0 ;; esac
  done
  return 1
}

log "старт (approve='${OPS_APPROVE}')"
[ -d "$OUTBOX" ] || { log "outbox отсутствует — выходим"; exit 0; }

REPO_OK=1
if [ ! -d "$REPO/.git" ]; then
  log "WARN: $REPO не git-репозиторий — работа с git невозможна"
  REPO_OK=0
fi

# Свежий main нужен дважды: для проверки «скрипт есть в main» и как база новых
# веток. Без fetch проверка отказывала бы на только что смерженном скрипте.
if [ "$REPO_OK" = "1" ]; then
  git -C "$REPO" fetch -q origin main 2>/dev/null \
    || log "WARN: fetch origin main не удался — проверка пойдёт по старому ref"
fi

# ---------- 1. запуск скриптов, уже влитых в main ----------
if [ -d "$OUTBOX/run" ]; then
  for req in "$OUTBOX/run"/*; do
    [ -f "$req" ] || continue
    name=$(basename "$req")
    case "$name" in
      *[!A-Za-z0-9._-]*|"") log "ОТКАЗ run: недопустимое имя '$name'"; continue ;;
    esac
    # Скрипт обязан быть в main, а не просто в клоне: иначе мержа не было.
    if [ "$REPO_OK" = "1" ] && ! git -C "$REPO" cat-file -e "origin/main:scripts/$name" 2>/dev/null; then
      log "ОТКАЗ run: scripts/$name нет в main (нужен PR+мерж) — заявка ждёт"
      continue
    fi

    mode="план"
    run_args=""
    if [ "$OPS_APPROVE" = "$name" ]; then
      mode="ПРИМЕНЕНИЕ (--yes, подтверждено человеком)"
      run_args="--yes"
    fi
    log "RUN scripts/$name — режим: $mode"
    ( cd "$REPO" && timeout "$RUN_TIMEOUT" bash "scripts/$name" $run_args ) \
      > "$LOGDIR/ops-run-$name.log" 2>&1
    rc=$?
    [ "$rc" = "124" ] && log "ВНИМАНИЕ: scripts/$name остановлен по timeout ${RUN_TIMEOUT}s"
    echo "rc=$rc" >> "$LOGDIR/ops-run-$name.log"
    log "DONE scripts/$name rc=$rc (вывод: logs/ops-run-$name.log)"
    mkdir -p "$OUTBOX/sent/run"
    mv -f -- "$req" "$OUTBOX/sent/run/$name.$rc" 2>/dev/null || true
  done
fi

# ---------- 2. публикация файлов в ветки agent/* ----------
if [ "$REPO_OK" = "1" ]; then
  mkdir -p "$OUTBOX/sent"
  # Гигиена: истории публикаций и мусор worktree не растут бесконечно.
  find "$OUTBOX/sent" -type f -mtime +"$SENT_DAYS" -delete 2>/dev/null
  find "$OUTBOX/sent" -type d -empty -delete 2>/dev/null
  git -C "$REPO" worktree prune >/dev/null 2>&1

  for bdir in "$OUTBOX"/*/; do
    [ -d "$bdir" ] || continue
    branch=$(basename "$bdir")
    case "$branch" in
      sent|run) continue ;;
    esac

    case "$branch" in
      "$BRANCH_PREFIX"*) : ;;
      *) log "ОТКАЗ ветку '$branch': публикуем только в ${BRANCH_PREFIX}*"; continue ;;
    esac
    for bad in $FORBIDDEN_BRANCHES; do
      if [ "$branch" = "$bad" ]; then
        log "ОТКАЗ ветку '$branch': запрещена"
        continue 2
      fi
    done

    files=$(cd "$bdir" && find . -type f | sed 's|^\./||')
    [ -n "$files" ] || continue

    # Сначала ПОЛНАЯ проверка, потом копирование (fail closed).
    fail=0
    while IFS= read -r f; do
      if [ -L "$bdir/$f" ] || [ ! -f "$bdir/$f" ] || ! path_ok "$f"; then
        log "ОТКАЗ ветку '$branch': недопустимый файл '$f'"
        fail=1
        break
      fi
    done <<< "$files"
    [ "$fail" = "0" ] || continue

    count=$(printf '%s\n' "$files" | wc -l)

    # Состояние удалённой ветки — ДО создания worktree: существующая ветка
    # продолжается от себя, иначе следующий выпуск затёр бы прежние файлы.
    remote_sha=$(git -C "$REPO" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
    if [ -n "$remote_sha" ]; then
      git -C "$REPO" fetch -q origin "refs/heads/$branch" 2>/dev/null
      tip_author=$(git -C "$REPO" log -1 --format='%ae' FETCH_HEAD 2>/dev/null)
      if [ "$tip_author" != "$SIGNER_EMAIL" ]; then
        log "ОТКАЗ ветку '$branch': её вершину создал не публикатор ($tip_author)"
        continue
      fi
    fi

    rm -rf "$WT"
    if ! git -C "$REPO" worktree add -f --detach "$WT" >/dev/null 2>&1; then
      log "ERROR: не создать worktree для '$branch'"
      continue
    fi
    if [ -n "$remote_sha" ]; then
      base=FETCH_HEAD
    else
      base=origin/main
    fi
    if ! git -C "$WT" checkout -B "$branch" "$base" >/dev/null 2>&1; then
      log "ERROR: не встать на базу '$base' для '$branch'"
      git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
      continue
    fi

    while IFS= read -r f; do
      mkdir -p "$WT/$(dirname "$f")"
      cp -f "$bdir/$f" "$WT/$f"
    done <<< "$files"

    git -C "$WT" add -A
    if git -C "$WT" diff --cached --quiet; then
      log "ветка $branch: содержимое уже такое же, коммит не нужен"
      git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
      continue
    fi

    sign_args=""
    if [ -n "$(git -C "$REPO" config user.signingkey 2>/dev/null)" ]; then
      sign_args="-S"
    fi
    git -C "$WT" -c "user.name=$SIGNER_NAME" -c "user.email=$SIGNER_EMAIL" \
        commit -q $sign_args -m "ops: публикация из outbox агента ($(date -Iseconds))"

    push_ok=0
    if [ -z "$remote_sha" ]; then
      if git -C "$WT" push -q origin "HEAD:refs/heads/$branch"; then
        push_ok=1
        log "ветка $branch: создана от origin/main, файлов: $count"
      else
        log "ERROR: push (создание) в '$branch' не удался"
      fi
    elif git -C "$WT" push -q --force-with-lease="refs/heads/$branch:$remote_sha" \
           origin "HEAD:refs/heads/$branch"; then
      push_ok=1
      log "ветка $branch: продолжена от своей вершины, файлов: $count"
    else
      log "ERROR: push в '$branch' не удался (lease не совпал — ветку кто-то двигал)"
    fi

    if [ "$push_ok" = "1" ]; then
      mkdir -p "$OUTBOX/sent/$branch"
      while IFS= read -r f; do
        mkdir -p "$OUTBOX/sent/$branch/$(dirname "$f")"
        mv -f "$bdir/$f" "$OUTBOX/sent/$branch/$f"
      done <<< "$files"
    fi

    git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  done
fi

log "готово"