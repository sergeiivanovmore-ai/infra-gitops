#!/bin/bash
# Публикация файлов агента из outbox в репозиторий — байт-в-байт, без модели.
#
# ЗАЧЕМ: у агента нет шелла и выхода в сеть, а запись через GitHub MCP идёт
# аргументом инструмента (контент набирает модель) — наблюдался 18-байтный
# огрызок вместо скрипта. Хост же ЧИТАЕТ workspace агента напрямую (bind
# /opt/docker/hermes-sysadmin/data/workspace), поэтому транспорт — файлы,
# содержимое не проходит через модель.
#
# ПОСЛЕ РЕВЬЮ БЕЗОПАСНОСТИ ПРАВА АГЕНТА ОГРАНИЧЕНЫ ЯВНО, В КОДЕ:
#   1) ветки только с префиксом agent/ — ветки человека и CI не трогаются вообще;
#   2) force-пуш разрешён ТОЛЬКО поверх ветки, вершину которой создал сам
#      публикатор; чужая вершина => отказ (историю человека/CI перезаписать нельзя);
#   3) пути только из белого списка ALLOWED_PATHS; .github/ (в частности
#      workflows с доступом к секретам), CODEOWNERS, Dockerfile, docker-compose*,
#      .gitignore и прочее, что влияет на сборку и деплой, запрещены;
#   4) симлинки в outbox отклоняются — иначе можно было бы вынести файл хоста;
#   5) скрипты запускаются БЕЗ аргументов, то есть в режиме плана. Режим
#      применения (--yes) включается только именем скрипта, которое человек
#      передал через ручной workflow_dispatch (OPS_APPROVE). У агента нет
#      инструмента запуска workflow, подделать это он не может;
#   6) main/master/HEAD запрещены жёстко; мерж остаётся человеческим.
#
# Структура outbox (в workspace агента):
#   outbox/agent/<тема>/<путь-в-репо>  — файл для публикации в ветку agent/<тема>
#   outbox/run/<имя-скрипта>           — запустить scripts/<имя-скрипта> из main
# После успеха файлы переезжают в outbox/sent/... и повторно не публикуются.
#
# Запускается workflow .github/workflows/ops-publish.yml: расписание + ручной
# запуск. Автозапуск пушем убран по ревью — агент не инициирует выполнение сам.
set -u

OUTBOX="/opt/docker/hermes-sysadmin/data/workspace/outbox"
LOGDIR="/opt/docker/hermes-sysadmin/data/logs"
REPO="/opt/infra-gitops"
WT="/tmp/ops-publish-wt"

BRANCH_PREFIX="agent/"
FORBIDDEN_BRANCHES="main master HEAD"
ALLOWED_PATHS="scripts/ docs/"
BLOCKED_PATHS=".github/ CODEOWNERS .gitignore .gitattributes Dockerfile docker-compose .env secrets/ .git/"
SIGNER_NAME="hermes-sysadmin"
SIGNER_EMAIL="hermes-sysadmin@localhost"
OPS_APPROVE="${OPS_APPROVE:-}"

mkdir -p "$LOGDIR" 2>/dev/null
# Дублируем вывод в лог, который агент читает локально: логи GitHub Actions
# агенту недоступны (403 даже на публичном репозитории).
exec >> "$LOGDIR/ops-publish.log" 2>&1

log() { echo "[$(date -Iseconds)] [ops-publish] $*"; }

# Проверка пути: белый список каталогов, чёрный список, никаких .. и симлинков.
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

# ---------- 1. запуск скриптов, уже влитых в main ----------
if [ -d "$OUTBOX/run" ]; then
  for req in "$OUTBOX/run"/*; do
    [ -f "$req" ] || continue
    name=$(basename "$req")
    case "$name" in
      *[!A-Za-z0-9._-]*|"") log "ОТКАЗ run: недопустимое имя '$name'"; continue ;;
    esac
    # Скрипт обязан быть в main, а не просто в клоне: иначе мержа не было.
    if [ -d "$REPO/.git" ] && ! git -C "$REPO" cat-file -e "origin/main:scripts/$name" 2>/dev/null; then
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
    ( cd "$REPO" && bash "scripts/$name" $run_args ) > "$LOGDIR/ops-run-$name.log" 2>&1
    rc=$?
    echo "rc=$rc" >> "$LOGDIR/ops-run-$name.log"
    log "DONE scripts/$name rc=$rc (вывод: logs/ops-run-$name.log)"
    mkdir -p "$OUTBOX/sent/run"
    mv -f -- "$req" "$OUTBOX/sent/run/$name.$rc" 2>/dev/null || true
  done
fi

# ---------- 2. публикация файлов в ветки agent/* ----------
if [ ! -d "$REPO/.git" ]; then
  log "WARN: $REPO не git-репозиторий — публикация пропущена"
  log "готово"
  exit 0
fi

mkdir -p "$OUTBOX/sent"
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

  rm -rf "$WT"
  if ! git -C "$REPO" worktree add -f --detach "$WT" >/dev/null 2>&1; then
    log "ERROR: не создать worktree для '$branch'"
    continue
  fi
  # Локальная ветка внутри одноразового worktree; удалённую не трогает.
  git -C "$WT" checkout -B "$branch" >/dev/null 2>&1 || true

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

  remote_sha=$(git -C "$WT" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
  push_ok=0
  if [ -z "$remote_sha" ]; then
    if git -C "$WT" push -q origin "HEAD:refs/heads/$branch"; then
      push_ok=1
      log "ветка $branch: создана, файлов: $count"
    else
      log "ERROR: push (создание) в '$branch' не удался"
    fi
  else
    git -C "$WT" fetch -q origin "refs/heads/$branch" 2>/dev/null
    tip_author=$(git -C "$WT" log -1 --format='%ae' FETCH_HEAD 2>/dev/null)
    if [ "$tip_author" != "$SIGNER_EMAIL" ]; then
      log "ОТКАЗ: вершину '$branch' создал не публикатор ($tip_author) — не перезаписываю"
    elif git -C "$WT" push -q --force-with-lease="refs/heads/$branch:$remote_sha" \
           origin "HEAD:refs/heads/$branch"; then
      push_ok=1
      log "ветка $branch: обновлена (force-with-lease), файлов: $count"
    else
      log "ERROR: push в '$branch' не удался (lease не совпал — ветку кто-то двигал)"
    fi
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

log "готово"