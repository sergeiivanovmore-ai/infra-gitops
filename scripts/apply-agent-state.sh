#!/bin/bash
# apply-agent-state.sh — возврат состояния агентов из приватного репозитория.
#
# Обратная сторона sync-agent-state.sh. Состояние (память и скрипты cron) живёт
# в приватном репозитории. После переезда на новый хост его нужно вернуть в
# каталоги данных агентов: память читает сам агент, а скрипты запускает cron —
# без них расписание приедет, а запускать по нему будет нечего.
#
# Правила:
#   * состав агентов берётся автообходом agents/*/models.yaml (ключ config:) —
#     тот же приём, что в sync-agent-state.sh, зашитых имён нет;
#   * копируются только *.py и *.sh: рантайм-мусору (executions.db, локи) в
#     каталоге скриптов места нет;
#   * файл на хосте — источник правды: если он новее, чем в состоянии, он не
#     перезаписывается, иначе деплой затирал бы свежие правки;
#   * владелец и группа берутся у каталога данных агента, режим 700;
#   * нет чекаута состояния — выходим с кодом 0: на новом хосте до первого
#     синка это нормально, и деплой из-за этого падать не должен.
#
# Использование: apply-agent-state.sh [--dry-run]
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/infra-gitops}"
STATE_DIR="${STATE_DIR:-/opt/agent-state-checkout}"
BRANCH="${STATE_BRANCH:-state/auto}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "неизвестный аргумент: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }

if [ ! -d "$REPO_DIR/agents" ]; then
  log "  состояние: нет $REPO_DIR/agents — неоткуда взять состав агентов"
  exit 0
fi
if [ ! -d "$STATE_DIR/.git" ]; then
  log "  состояние: нет чекаута $STATE_DIR — пропускаю (на новом хосте это нормально до первого синка)"
  exit 0
fi

cd "$STATE_DIR"
# Свежая ветка состояния — хорошо, но сеть может быть недоступна: тогда
# работаем с тем, что уже лежит в чекауте, и говорим об этом.
if [ "$DRY_RUN" = "0" ]; then
  git fetch --quiet origin 2>/dev/null \
    || log "  состояние: не удалось обновить чекаут — работаю с текущим"
  git checkout --quiet "$BRANCH" 2>/dev/null \
    || log "  состояние: ветка $BRANCH недоступна — работаю с текущим чекаутом"
fi

applied=0
skipped=0
for models in "$REPO_DIR"/agents/*/models.yaml; do
  [ -e "$models" ] || continue
  name="$(basename "$(dirname "$models")")"
  cfg="$(sed -n 's/^config:[[:space:]]*//p' "$models" | head -1)"
  cfg="${cfg%% *}"
  [ -z "$cfg" ] && continue
  dir="$(dirname "$cfg")"
  # Агент есть в составе, но не развёрнут на этом хосте — трогать нечего.
  [ -d "$dir" ] || continue
  src="$STATE_DIR/agents/$name/state/scripts"
  [ -d "$src" ] || continue

  for f in "$src"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      *.py|*.sh) ;;
      *) continue ;;
    esac
    dst="$dir/scripts/$base"
    if [ -f "$dst" ] && [ "$dst" -nt "$f" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$DRY_RUN" = "1" ]; then
      log "  состояние: $name/$base -> $dst (план)"
      applied=$((applied + 1))
      continue
    fi
    mkdir -p "$dir/scripts"
    cp -f "$f" "$dst"
    owner="$(stat -c '%u:%g' "$dir")"
    chown "$owner" "$dst" 2>/dev/null || true
    chmod 700 "$dst"
    applied=$((applied + 1))
    log "  состояние: $name/$base -> $dst"
  done
done

if [ "$DRY_RUN" = "1" ]; then
  log "  состояние: план — к возврату $applied, пропущено (на хосте новее) $skipped"
else
  log "  состояние: возвращено файлов $applied, пропущено (на хосте новее) $skipped"
fi
exit 0
