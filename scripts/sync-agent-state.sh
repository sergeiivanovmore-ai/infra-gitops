#!/usr/bin/env bash
# sync-agent-state.sh — выгрузка состояния Hermes-агентов в приватный репозиторий.
#
# Слой 2 архитектуры (см. proposals/2026-10-25-agent-state-versioning.md):
# скиллы, созданные агентами, и память. Меняется часто, поэтому идёт не через
# PR, а автокоммитом в ветку state/auto. Раз в неделю — консолидирующий PR
# state/auto -> main, вручную, в приватном репозитории.
#
# Два репозитория, и это существенно:
#   infra-gitops       (публичный) — ОТКУДА берётся СОСТАВ: agents/*/models.yaml
#                                    задаёт список агентов и их каталоги данных.
#   hermes-agent-state (приватный) — КУДА пишется СОСТОЯНИЕ: agents/<агент>/state/.
# Состав и состояние специально разведены: память и навыки, накопленные агентами,
# не должны оказаться в публичном репозитории.
#
# Автообнаружение: обходим agents/*/models.yaml, зашитых имён агентов и таблицы
# «имя -> каталог» в скрипте нет. Каталог данных агента берётся из ключа config:
# его же models.yaml. Новый агент появится — состояние начнёт синкаться само.
#
# Использование:
#   sync-agent-state.sh [--dry-run]
#
# Крон на хосте, по образцу ops-publish.sh и health-check.sh.

set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/infra-gitops}"                 # состав агентов
STATE_REPO="${STATE_REPO:-https://github.com/sergeiivanovmore-ai/hermes-agent-state.git}"
STATE_DIR="${STATE_DIR:-/opt/agent-state-checkout}"       # чекаут состояния
STATE_TOKEN_FILE="${STATE_TOKEN_FILE:-/root/.github-agent-state-token}"
BRANCH="${STATE_BRANCH:-state/auto}"
MAX_FILE_SIZE="${MAX_FILE_SIZE:-1048576}"                 # 1 МиБ
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "неизвестный аргумент: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }

# Синкается только перечисленное. Белый список, а не чёрный: всё, что не названо
# явно, в репозиторий не попадает — в том числе .env, сессии, кэш, архивы.
STATE_SUBDIRS=(skills memories)

[ -d "$REPO_DIR/agents" ] || { log "нет $REPO_DIR/agents — неоткуда взять состав агентов"; exit 1; }

# --- токен доступа к приватному репозиторию ----------------------------------
# Токен живёт в файле и передаётся git через GIT_ASKPASS: в командной строке его
# нет вообще, поэтому он не виден в ps другим пользователям хоста. В .git/config
# он тоже не оседает — remote остаётся публичным адресом.
token=""
if [ -f "$STATE_TOKEN_FILE" ]; then
  token="$(tr -d '\n' < "$STATE_TOKEN_FILE")"
fi

if [ -n "$token" ]; then
  export HERMES_STATE_TOKEN="$token"
  askpass="$(mktemp)"
  cat > "$askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
  *sername*) printf '%s' "x-access-token" ;;
  *)         printf '%s' "$HERMES_STATE_TOKEN" ;;
esac
ASKPASS
  chmod 700 "$askpass"
  trap 'rm -f "$askpass"' EXIT
  export GIT_ASKPASS="$askpass"
fi
export GIT_TERMINAL_PROMPT=0

# Репозиторий по HTTPS без токена — клонировать и пушить нечем.
need_token() {
  [ -z "$token" ] && [ "${STATE_REPO#https://}" != "$STATE_REPO" ]
}

# --- клонирование или подтягивание репозитория состояния ---------------------
if [ ! -d "$STATE_DIR/.git" ]; then
  if need_token; then
    log "нет $STATE_DIR и нет токена в $STATE_TOKEN_FILE — клонировать нечем"
    exit 1
  fi
  log "клонирую репозиторий состояния в $STATE_DIR"
  mkdir -p "$(dirname "$STATE_DIR")"
  git clone --quiet "$STATE_REPO" "$STATE_DIR"
fi

cd "$STATE_DIR"
if [ -n "$(git status --porcelain)" ]; then
  log "в $STATE_DIR есть незакоммиченные изменения — не трогаю, разберитесь вручную"
  exit 1
fi

git fetch --quiet origin
# Базируемся на существующей ветке состояния, если она есть: иначе повторный
# прогон пересоздал бы ветку от main и push был бы не-fast-forward.
if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  git checkout --quiet -B "$BRANCH" "origin/$BRANCH"
else
  git checkout --quiet -B "$BRANCH" "origin/main"
fi

# --- кто синкается: автообнаружение по models.yaml в репозитории состава -----
agents=()
data_dirs=()
for models in "$REPO_DIR"/agents/*/models.yaml; do
  [ -e "$models" ] || continue
  name="$(basename "$(dirname "$models")")"
  cfg="$(sed -n 's/^config:[[:space:]]*//p' "$models" | head -1)"
  cfg="${cfg%% *}"
  if [ -z "$cfg" ]; then
    log "  $name: в models.yaml нет ключа config — пропуск"
    continue
  fi
  dir="$(dirname "$cfg")"
  if [ ! -d "$dir" ]; then
    log "  $name: каталог данных $dir недоступен — пропуск"
    continue
  fi
  agents+=("$name")
  data_dirs+=("$dir")
done

if [ ${#agents[@]} -eq 0 ]; then
  log "под $REPO_DIR/agents/*/models.yaml не найден ни один агент — синкать нечего"
  exit 0
fi
log "агентов к синку: ${#agents[@]} — ${agents[*]}"

# --- копирование состояния ---------------------------------------------------
changed=0
for i in "${!agents[@]}"; do
  name="${agents[$i]}"
  dir="${data_dirs[$i]}"
  dest="agents/$name/state"

  for sub in "${STATE_SUBDIRS[@]}"; do
    src="$dir/$sub"
    [ -d "$src" ] || continue
    mkdir -p "$dest/$sub"
    # Предохранитель: пустой источник при непустом зеркале — почти всегда сбой
    # (не смонтировался том, контейнер пересоздан), а не осознанное удаление
    # агентом всего своего состояния. Без него --delete снёс бы ветку.
    src_n=$(find "$src" -type f ! -name '*.tmp' 2>/dev/null | wc -l)
    dst_n=$(find "$dest/$sub" -type f 2>/dev/null | wc -l)
    if [ "$src_n" -eq 0 ] && [ "$dst_n" -gt 0 ]; then
      log "  $name/$sub: источник пуст, а в репозитории $dst_n файлов — пропуск (сбой монтирования?)"
      continue
    fi
    # Не тащим в состояние то, что и так лежит в публичном репозитории: скиллы,
    # которые деплой раздаёт агенту, живут в infra-gitops agents/<имя>/skills/.
    excludes=()
    if [ "$sub" = "skills" ]; then
      for shipped in "$REPO_DIR"/agents/"$name"/skills/*/; do
        [ -e "$shipped" ] || continue
        excludes+=(--exclude="$(basename "$shipped")/")
      done
    fi
    if [ "$DRY_RUN" = "1" ]; then
      n=$(rsync --dry-run --recursive --itemize-changes \
            --max-size="$MAX_FILE_SIZE" \
            --exclude='.archive/' --exclude='*.tmp' "${excludes[@]}" \
            "$src/" "$dest/$sub/" | grep -c '^>' || true)
      [ "$n" -gt 0 ] && { log "  $name/$sub: изменится файлов $n"; changed=1; }
    else
      # --delete здесь безопасен: приёмник — зеркало состояния в репозитории,
      # а не живой каталог агента. Удалённый агентом файл должен уйти и из Git.
      # Исключённые каталоги --delete не трогает: --delete-excluded не выставлен.
      rsync --archive --delete --max-size="$MAX_FILE_SIZE" \
            --exclude='.archive/' --exclude='*.tmp' "${excludes[@]}" \
            "$src/" "$dest/$sub/"
    fi
  done
done

if [ "$DRY_RUN" = "1" ]; then
  [ "$changed" = "0" ] && log "изменений нет"
  log "dry-run: ничего не записано"
  exit 0
fi

# --- коммит и публикация -----------------------------------------------------
git add -A agents/*/state 2>/dev/null || true
if git diff --cached --quiet; then
  log "изменений нет — коммит не нужен"
  exit 0
fi

summary="$(git diff --cached --numstat | awk '{a+=$1; d+=$2; f++} END {printf "%d файлов, +%d/-%d строк", f, a, d}')"
log "к коммиту: $summary"

git -c user.name="hermes-state-sync" \
    -c user.email="state-sync@localhost" \
    commit --quiet -m "state: синк состояния агентов ($summary)"
git push --quiet origin "HEAD:$BRANCH"
log "запушено в репозиторий состояния, ветка $BRANCH"

# Проверка выравнивания: сколько файлов состояния лежит в репозитории.
for name in "${agents[@]}"; do
  n=$(find "agents/$name/state" -type f 2>/dev/null | wc -l)
  log "  $name: файлов состояния в репозитории — $n"
done
