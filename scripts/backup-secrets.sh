#!/bin/bash
# Инвентарь секретов, сухой прогон и бэкап в R2 через restic.
#
# Режимы:
#   --inventory  список файлов, которые попадут в бэкап: путь, размер, права.
#                Ничего не пишет и в репозиторий R2 не обращается.
#   --dry-run    то же плюс проверка ключей, пароля и прав. Ничего не пишет.
#                Ненулевой код означает «к бэкапу не готово».
#   --yes        реальный бэкап: restic backup с тегом, forget с политикой
#                удержания, check с выборочным чтением данных.
#
# Состав бэкапа не захардкожен: агентские .env находятся обходом
# $DOCKER_DIR/hermes*/data/.env, поэтому новый агент попадёт в бэкап сам.
#
# Пути задаются явными переменными — каждая со своим боевым значением по
# умолчанию. Префиксного «корня» здесь нет намеренно: префикс легко задать как
# /root и получить /root/root/.restic-password, то есть молча неверные пути.
# Переопределение нужно, чтобы механизм проверялся на стенде, не касаясь
# боевых каталогов.
set -euo pipefail

DOCKER_DIR="${BACKUP_DOCKER_DIR:-/opt/docker}"
CREDENTIALS="${BACKUP_CREDENTIALS:-/root/.config/restic/credentials}"
PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/root/.restic-password}"
STATE_TOKEN="${BACKUP_STATE_TOKEN:-/root/.github-agent-state-token}"
AUDIT_TOKEN="${BACKUP_AUDIT_TOKEN:-/root/.github-audit-token}"

# Политика удержания снапшотов.
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
CHECK_SUBSET=5%

# Что в бэкап не попадает никогда, даже если окажется в списке: расписание cron
# уже ездит в hermes-agent-state, локи и базы — рантайм-мусор, а файл пароля
# restic и файл ключей S3 не должны попадать в бэкап ни при каких обстоятельствах
# (иначе хранилище открывается своим же содержимым).
EXCLUDE_RE='(^|/)(jobs\.json|restic-password|credentials|.*\.(db|lock|tmp))$'

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

MODE=""
for arg in "$@"; do
  case "$arg" in
    --inventory) MODE="inventory" ;;
    --dry-run)   MODE="dry-run" ;;
    --yes)       MODE="backup" ;;
    *)
      echo "неизвестный аргумент: $arg" >&2
      exit 2 ;;
  esac
done
if [ -z "$MODE" ]; then
  echo "укажите режим: --inventory, --dry-run или --yes" >&2
  exit 2
fi

files=()
missing=0

# Регистрация файла в списке. $1 — путь, $2 — "1", если файл обязателен.
add_file() {
  local path="$1" req="$2"
  if printf '%s' "$path" | grep -qE "$EXCLUDE_RE"; then
    printf '  %-58s исключён по правилу\n' "$path"
    return
  fi
  if [ -f "$path" ]; then
    files+=("$path")
    return
  fi
  if [ "$req" = "1" ]; then
    printf '  %-58s НЕТ (ожидался обязательный файл)\n' "$path"
    missing=$((missing + 1))
  else
    printf '  %-58s нет — пропуск\n' "$path"
  fi
}

echo "=== СОСТАВ БЭКАПА СЕКРЕТОВ ==="
covered=""
shopt -s nullglob
for f in "$DOCKER_DIR"/hermes*/data/.env; do
  add_file "$f" 1
  covered="$covered $(basename "$(dirname "$(dirname "$f")")")"
done
shopt -u nullglob
add_file "$DOCKER_DIR/dsh/data/settings.yaml" 1
add_file "$STATE_TOKEN" 1
add_file "$AUDIT_TOKEN" 0

# Страховка от тихой потери. Если каталог контейнера выглядит как агент (есть
# data/config.yaml), но в список не попал — значит имя не подошло под обход, и
# его секреты уехали бы мимо бэкапа. Об этом надо кричать, а не молчать.
missed="0"
for c in "$DOCKER_DIR"/*/data/config.yaml; do
  [ -f "$c" ] || continue
  d="$(basename "$(dirname "$(dirname "$c")")")"
  case " $covered " in
    *" $d "*) continue ;;
  esac
  printf '  %-58s ВНИМАНИЕ: похож на агента, но в список не попал\n' "$c"
  missed=$((missed + 1))
done

if [ "${#files[@]}" -eq 0 ]; then
  log "ОСТАНОВ: ни одного файла для бэкапа не найдено"
  exit 1
fi

echo
echo "=== ФАЙЛЫ К ОТПРАВКЕ ==="
total=0
for f in "${files[@]}"; do
  size="$(stat -c %s -- "$f")"
  mode="$(stat -c %a -- "$f")"
  total=$((total + size))
  printf '  %-58s %9s Б  права %s\n' "$f" "$size" "$mode"
done
printf 'итого: файлов %d, размер %d Б\n' "${#files[@]}" "$total"

if [ "$MODE" = "inventory" ]; then
  echo
  echo "режим --inventory: только список, ничего не записано"
  exit 0
fi

# --- проверки доступа: значения не печатаются ---------------------------------
echo
echo "=== ДОСТУП К ХРАНИЛИЩУ ==="

PERMS_BAD=""
check_file() {
  local name="$1" path="$2"
  if [ ! -f "$path" ]; then
    printf '  %-46s НЕТ\n' "$name"
    return 1
  fi
  local mode
  mode="$(stat -c %a -- "$path")"
  if [ "$mode" = "600" ]; then
    printf '  %-46s есть, права %s\n' "$name" "$mode"
  else
    printf '  %-46s есть, права %s — ОЖИДАЛОСЬ 600\n' "$name" "$mode"
    echo "WARNING: $path имеет права $mode, ожидалось 600" >&2
    PERMS_BAD="$PERMS_BAD $path($mode)"
  fi
  return 0
}

perms_ok=1
creds_ok=1
check_file "credentials (ключи S3)" "$CREDENTIALS" || creds_ok=0
check_file "password (пароль restic)" "$PASSWORD_FILE" || creds_ok=0

# И сами файлы секретов. .env агентов — это и есть содержимое бэкапа, поэтому
# читаемый посторонним .env внутри снапшота — ровно та же дыра, что читаемый
# пароль: секрет уже раскрыт, снапшот лишь фиксирует это. Проверка идёт тем же
# check_file, поэтому плохие права попадают в PERMS_BAD.
for f in "${files[@]}"; do
  check_file "$f" "$f" || perms_ok=0
done

if [ -n "$PERMS_BAD" ]; then
  perms_ok=0
fi

# Значения читаются построчно и НЕ подставляются через shell: пароль и ключи
# могут содержать знаки $ и другие символы, которые source исказил бы. Ни одна
# из величин здесь не печатается — только имя переменной и вердикт.
for key in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_REPOSITORY; do
  if [ -f "$CREDENTIALS" ] && grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$CREDENTIALS"; then
    printf '  %-46s есть\n' "$key"
  else
    printf '  %-46s НЕТ\n' "$key"
    creds_ok=0
  fi
done

if [ -f "$CREDENTIALS" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in export\ *) line="${line#export }" ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    case "$key" in
      AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|RESTIC_REPOSITORY|AWS_DEFAULT_REGION)
        if [ -z "$val" ]; then
          printf '  %-46s пустое значение\n' "$key"
          creds_ok=0
        elif [ "$key" = "RESTIC_REPOSITORY" ] && [ "${val#s3:}" = "$val" ]; then
          # Подсказка, а не отказ: иначе рабочая, но иначе записанная строка
          # заблокирует бэкап. Настоящую ошибку адреса покажет сам restic.
          printf '  %-46s не начинается с s3: — проверьте адрес\n' "$key"
        fi
        export "$key=$val" ;;
    esac
  done < "$CREDENTIALS"
fi

ready=1
if [ "$missing" -gt 0 ] || [ "$missed" != "0" ] || [ "$perms_ok" != "1" ] || [ "$creds_ok" != "1" ]; then
  ready=0
fi

if [ "$MODE" = "dry-run" ]; then
  echo
  if [ "$missing" -gt 0 ]; then
    echo "ВНИМАНИЕ: не найдено обязательных файлов: $missing"
  fi
  if [ "$missed" != "0" ]; then
    echo "ВНИМАНИЕ: каталогов, похожих на агентов, но не попавших в список: $missed"
  fi
  if [ "$creds_ok" != "1" ]; then
    echo "ВНИМАНИЕ: доступ к хранилищу не подтверждён"
  fi
  if [ "$perms_ok" != "1" ]; then
    echo "ВНИМАНИЕ: небезопасные права:$PERMS_BAD"
  fi
  if [ "$ready" = "1" ]; then
    log "ИТОГ: к бэкапу готово; ничего не записано"
    exit 0
  fi
  log "ИТОГ: к бэкапу НЕ готово (см. предупреждения выше); ничего не записано"
  exit 1
fi

# ── --yes: реальный бэкап ────────────────────────────────────────────────────
# До этой точки ничего в R2 не уходит. Отказ, а не предупреждение: неполный
# состав или читаемый посторонним пароль — это не «продолжим с оговоркой».
if [ "$missing" -gt 0 ] || [ "$missed" != "0" ]; then
  log "ОСТАНОВ: состав неполон (см. выше) — бэкап не запускаю"
  exit 2
fi
if [ "$perms_ok" != "1" ]; then
  log "ОСТАНОВ: небезопасные права ($PERMS_BAD) — бэкап не запускаю"
  exit 2
fi
if [ "$creds_ok" != "1" ]; then
  log "ОСТАНОВ: ключи доступа не подтверждены — бэкап не запускаю"
  exit 2
fi
if ! command -v restic >/dev/null 2>&1; then
  log "ОСТАНОВ: restic не найден в PATH"
  exit 1
fi

# restic берёт пароль из этой переменной, поэтому её надо именно экспортировать.
export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

# Счётчик снапшотов: необязательная косметика, поэтому при любой неудаче — 0,
# а не падение. Точные числа всё равно видны в выводе restic.
snapshot_count() {
  local n
  n="$(restic snapshots --json 2>/dev/null | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
print(len(d) if isinstance(d, list) else 0)' 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

snapshot_id() {
  restic snapshots --json 2>/dev/null | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
if isinstance(d, list) and d:
    print(d[-1].get("short_id") or d[-1].get("id", ""))' 2>/dev/null || true
}

log "начало бэкапа секретов: файлов ${#files[@]}, размер $total Б"

if ! restic backup --tag secrets "${files[@]}"; then
  log "ОШИБКА: restic backup завершился с ошибкой"
  exit 1
fi

sid="$(snapshot_id)"
after_backup="$(snapshot_count)"
if [ "$after_backup" = "0" ]; then
  # Счёт через --json может не поддержаться версией restic. Тогда честнее
  # сказать об этом, чем показывать нули как настоящее число снапшотов.
  log "snapshot: ${sid:-не определён}; счёт снапшотов недоступен (см. вывод restic выше)"
else
  log "snapshot: ${sid:-не определён}; снапшотов в хранилище: $after_backup"
fi

if ! restic forget --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
     --keep-monthly "$KEEP_MONTHLY" --prune; then
  log "ОШИБКА: restic forget --prune завершился с ошибкой"
  exit 1
fi
after_forget="$(snapshot_count)"
if [ "$after_backup" = "0" ]; then
  log "политика: daily $KEEP_DAILY / weekly $KEEP_WEEKLY / monthly $KEEP_MONTHLY применена"
else
  log "политика: daily $KEEP_DAILY / weekly $KEEP_WEEKLY / monthly $KEEP_MONTHLY; снапшотов $after_backup -> $after_forget (удалено $((after_backup - after_forget)))"
fi

if ! restic check --read-data-subset="$CHECK_SUBSET"; then
  log "ОШИБКА: restic check нашёл проблемы в хранилище"
  exit 1
fi
log "check: OK (выборочное чтение данных $CHECK_SUBSET)"
log "бэкап завершён успешно"
exit 0
