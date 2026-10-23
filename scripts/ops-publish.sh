#!/bin/bash
# Публикация файлов агента из outbox в репозиторий — байт-в-байт, без модели.
#
# ЗАЧЕМ: у агента нет шелла и выхода в сеть, а запись через GitHub MCP идёт
# аргументом инструмента (контент набирает модель). Хост же ЧИТАЕТ workspace
# агента напрямую (bind /opt/docker/hermes-sysadmin/data/workspace), поэтому
# транспорт — файлы, содержимое не проходит через модель.
#
# РАЗДЕЛЕНИЕ КАНАЛОВ:
#   * автоматический путь (этот скрипт) несёт только КОНТЕНТ (docs/) и запуск
#     уже влитых скриптов. Каталог scripts/ здесь ЗАПРЕЩЁН: иначе агент мог бы
#     ревьюируемым PR дописать себе «одобренный» скрипт и тут же его выполнить.
#     Правки того, что исполняется, идут только через отдельный, заметный канал —
#     ручной PR по GitHub MCP, с ревью и мержем;
#   * исполнение: запускается только то, что лежит в main, без аргументов, то
#     есть в режиме плана.
#
# СТРУКТУРА OUTBOX (в workspace агента):
#   outbox/agent/<тема>/<путь-в-репо>  — публикуется в ветку agent/<тема>
#   outbox/run/<имя-скрипта>           — запустить scripts/<имя-скрипта> из main
#   outbox/stuck/...                   — «застрявшее», только для ручного разбора
#   outbox/sent/...                    — опубликованное, хранится 14 дней
#   outbox/.state/                     — счётчики отказов
# Имя ветки разбирается однозначно: префикс agent/ — ровно один сегмент, тема —
# следующий. Каталоги верхнего уровня, кроме перечисленных, не публикуются, и о
# каждом пишется предупреждение в лог, чтобы файл не «пропадал» молча.
#
# ОГРАНИЧЕНИЯ, ЗАШИТЫЕ В КОД:
#   1) ветки только agent/<тема>; main/master/HEAD запрещены жёстко;
#   2) ветка ПРОДОЛЖАЕТСЯ от своего текущего состояния (fetch + checkout от
#      FETCH_HEAD), для новой ветки база — свежий origin/main. Иначе следующий
#      выпуск собирался бы от main и молча затирал прежние файлы;
#   3) пуш: новая ветка — создание, существующая — только --force-with-lease,
#      прибитый к SHA, который реально наблюдали: после fetch берётся
#      rev-parse FETCH_HEAD, иначе гонка между ls-remote и fetch даёт ложный
#      отказ с неверной причиной в логе;
#   4) пути: белый список ALLOWED_PATHS, чёрный список BLOCKED_PATHS, проверка
#      ДО копирования, один плохой файл отклоняет всю ветку (fail closed);
#   5) симлинки попадают в список через -type l и отклоняются ЯВНО, а не
#      игнорируются молча;
#   6) режим применения (--yes) включается только именем скрипта, переданным
#      человеком через ручной workflow_dispatch (OPS_APPROVE). Инструмента
#      запуска workflow у агента нет — подделать нельзя;
#   7) запуск скрипта под timeout, свой лог ротируется по размеру;
#   8) отказы не могут длиться вечно: после STUCK_AFTER отказов подряд файлы
#      переезжают в outbox/stuck/<ветка> с громкой записью в лог.
#
# ВАЖНО О ГРАНИЦАХ: проверка автора вершины — это SAFETY (защита от собственной
# логической ошибки публикатора), а не security-граница: email автора
# подделывается, а кто может пушить в agent/*, у того и так есть права.
# Настоящая защита — ревью PR, CODEOWNERS и ruleset на main.
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
STUCK_AFTER=3
STATE_DIR="$OUTBOX/.state"

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

# Счётчик отказов по ветке: после STUCK_AFTER отказов подряд файлы уезжают в
# outbox/stuck/, чтобы публикация не «застревала» молча навсегда.
refuse() {
  local bdir="$1" branch="$2" reason="$3"
  local cf="$STATE_DIR/${branch//\//__}.refusals"
  local n=0
  mkdir -p "$STATE_DIR" 2>/dev/null
  [ -f "$cf" ] && n=$(cat "$cf" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$cf" 2>/dev/null
  log "ОТКАЗ ветку '$branch': $reason (отказов подряд: $n)"
  if [ "$n" -ge "$STUCK_AFTER" ]; then
    mkdir -p "$(dirname "$OUTBOX/stuck/$branch")" 2>/dev/null
    if [ ! -e "$OUTBOX/stuck/$branch" ]; then
      mv -f "$bdir" "$OUTBOX/stuck/$branch" 2>/dev/null || true
    else
      mv -f "$bdir" "$OUTBOX/stuck/$branch.$(date +%s)" 2>/dev/null || true
    fi
    rm -f "$cf" 2>/dev/null
    log "ВНИМАНИЕ: '$branch' отказал $n раз подряд — файлы перенесены в outbox/stuck/$branch, нужен ручной разбор"
  fi
}

clear_refusals() {
  rm -f "$STATE_DIR/${1//\//__}.refusals" 2>/dev/null
}

log "старт (approve='${OPS_APPROVE}')"
[ -d "$OUTBOX" ] || { log "outbox отсутствует — выходим"; exit 0; }

REPO_OK=1
if [ ! -d "$REPO/.git" ]; then
  log "WARN: $REPO не git-репозиторий — работа с git невозможна"
  REPO_OK=0
fi

# Уборка при аварийном завершении (например, SIGTERM от таймаута workflow):
# иначе недоделанные worktree копятся в .git/worktrees.
trap 'git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true' EXIT

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
    # Здесь отказ НЕ считается «застреванием»: заявка на только что открытый
    # PR обязана дождаться мержа, и это нормальное ожидание, а не тупик.
    if [ "$REPO_OK" = "1" ] && ! git -C "$REPO" cat-file -e "origin/main:scripts/$name" 2>/dev/null; then
      log "ЖДЁТ run: scripts/$name нет в main (нужен PR+мерж)"
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

# ---------- 2. публикация файлов в ветки agent/<тема> ----------
if [ "$REPO_OK" = "1" ]; then
  mkdir -p "$OUTBOX/sent"
  # Гигиена: истории публикаций и мусор worktree не растут бесконечно.
  find "$OUTBOX/sent" -type f -mtime +"$SENT_DAYS" -delete 2>/dev/null
  find "$OUTBOX/sent" -type d -empty -delete 2>/dev/null
  find "$STATE_DIR" -type f -mtime +"$SENT_DAYS" -delete 2>/dev/null
  git -C "$REPO" worktree prune >/dev/null 2>&1

  # Каталоги верхнего уровня, которые не публикуются, — сообщаем громко, иначе
  # положенный не туда файл «пропадал» бы молча.
  for stray in "$OUTBOX"/*/; do
    [ -d "$stray" ] || continue
    case "$(basename "$stray")" in
      agent|sent|run|stuck|.state) continue ;;
    esac
    log "ВНИМАНИЕ: каталог '$(basename "$stray")' не публикуется — нужен путь outbox/${BRANCH_PREFIX}<тема>/"
  done

  # Имя ветки разбирается однозначно: префикс занимает ровно один сегмент,
  # поэтому ветка = agent/<тема>, а содержимое — внутри каталога темы.
  for bdir in "$OUTBOX/$BRANCH_PREFIX"*/; do
    [ -d "$bdir" ] || continue
    theme=$(basename "$bdir")
    branch="${BRANCH_PREFIX}${theme}"

    for bad in $FORBIDDEN_BRANCHES; do
      if [ "$theme" = "$bad" ] || [ "$branch" = "$bad" ]; then
        log "ОТКАЗ ветку '$branch': запрещена"
        continue 2
      fi
    done

    # Симлинки тоже попадают в список (-type l), чтобы отказ был явным.
    files=$(cd "$bdir" && find . \( -type f -o -type l \) | sed 's|^\./||')
    [ -n "$files" ] || continue

    # Сначала ПОЛНАЯ проверка, потом копирование (fail closed).
    fail=""
    while IFS= read -r f; do
      if [ -L "$bdir/$f" ]; then
        fail="симлинк '$f' не публикуется"
      elif [ ! -f "$bdir/$f" ]; then
        fail="не обычный файл '$f'"
      elif ! path_ok "$f"; then
        fail="путь '$f' вне белого списка или в чёрном"
      fi
      [ -n "$fail" ] && break
    done <<< "$files"
    if [ -n "$fail" ]; then
      refuse "$bdir" "$branch" "$fail"
      continue
    fi

    count=$(printf '%s\n' "$files" | wc -l)

    # Состояние удалённой ветки — ДО создания worktree: существующая ветка
    # продолжается от себя, иначе следующий выпуск затёр бы прежние файлы.
    remote_sha=$(git -C "$REPO" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
    if [ -n "$remote_sha" ]; then
      # SHA перечитывается ПОСЛЕ fetch: между ls-remote и fetch ветку могли
      # сдвинуть, и lease, прибитый к устаревшему значению, дал бы ложный отказ.
      if git -C "$REPO" fetch -q origin "refs/heads/$branch" 2>/dev/null; then
        remote_sha=$(git -C "$REPO" rev-parse FETCH_HEAD 2>/dev/null)
      else
        refuse "$bdir" "$branch" "ветку не удалось получить (удалена между проверками?)"
        continue
      fi
      tip_author=$(git -C "$REPO" log -1 --format='%ae' FETCH_HEAD 2>/dev/null)
      if [ "$tip_author" != "$SIGNER_EMAIL" ]; then
        refuse "$bdir" "$branch" "вершину создал не публикатор ($tip_author)"
        continue
      fi
    fi

    rm -rf "$WT"
    if ! git -C "$REPO" worktree add -f --detach "$WT" >/dev/null 2>&1; then
      refuse "$bdir" "$branch" "не создать worktree"
      continue
    fi
    if [ -n "$remote_sha" ]; then
      base=FETCH_HEAD
    else
      base=origin/main
    fi
    if ! git -C "$WT" checkout -B "$branch" "$base" >/dev/null 2>&1; then
      refuse "$bdir" "$branch" "не встать на базу '$base'"
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
      clear_refusals "$branch"
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
        refuse "$bdir" "$branch" "push (создание) не удался"
      fi
    elif git -C "$WT" push -q --force-with-lease="refs/heads/$branch:$remote_sha" \
           origin "HEAD:refs/heads/$branch"; then
      push_ok=1
      log "ветка $branch: продолжена от своей вершины, файлов: $count"
    else
      refuse "$bdir" "$branch" "push отвергнут: lease не совпал — ветку сдвинули"
    fi

    if [ "$push_ok" = "1" ]; then
      clear_refusals "$branch"
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