#!/bin/bash
# Инвентарь секретов и сухой прогон их бэкапа в R2 через restic.
#
# Режимы:
#   --inventory  список файлов, которые попадут в бэкап: путь, размер, права.
#                Ничего не пишет и в репозиторий R2 не обращается.
#   --dry-run    то же плюс итог, проверка ключей и пароля restic. Тоже ничего
#                не пишет: ни в R2, ни в .env.
#   --yes        реальный restic backup. Появится отдельным PR вместе с cron —
#                до него скрипт отказывается, чтобы случайный запуск не отправил
#                секреты в хранилище.
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

# Что в бэкап не попадает никогда, даже если окажется в списке: расписание cron
# уже ездит в hermes-agent-state, локи и базы — рантайм-мусор, а файл пароля
# restic и файл ключей S3 не должны попадать в бэкап ни при каких обстоятельствах
# (иначе хранилище открывается своим же содержимым).
EXCLUDE_RE='(^|/)(jobs\.json|restic-password|credentials|.*\.(db|lock|tmp))$'

MODE=""
for arg in "$@"; do
  case "$arg" in
    --inventory) MODE="inventory" ;;
    --dry-run)   MODE="dry-run" ;;
    --yes)
      echo "ОСТАНОВ: реальный бэкап появится отдельным PR вместе с cron." >&2
      echo "Сейчас доступны только --inventory и --dry-run." >&2
      exit 2 ;;
    *)
      echo "неизвестный аргумент: $arg" >&2
      exit 2 ;;
  esac
done
if [ -z "$MODE" ]; then
  echo "укажите режим: --inventory или --dry-run" >&2
  exit 2
fi

files=()
required=()
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
    required+=("$req")
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
  echo "ОСТАНОВ: ни одного файла для бэкапа не найдено" >&2
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

# --- проверки доступа к хранилищу: значения не печатаются --------------------
echo
echo "=== ДОСТУП К ХРАНИЛИЩУ ==="

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
  fi
}

creds_ok=0
check_file "credentials (ключи S3)" "$CREDENTIALS" && creds_ok=1 || true
check_file "password (пароль restic)" "$PASSWORD_FILE" || creds_ok=0

# Значения читаются построчно и НЕ подставляются через shell: пароль и ключи
# могут содержать знаки $ и другие символы, которые source исказил бы. Ни одна
# из величин здесь не печатается — только имя переменной и вердикт.
for key in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_REPOSITORY; do
  if [ "$creds_ok" = "1" ] && grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$CREDENTIALS"; then
    printf '  %-46s есть\n' "$key"
  else
    printf '  %-46s НЕТ\n' "$key"
    creds_ok=0
  fi
done

if [ "$creds_ok" = "1" ]; then
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
          printf '  %-46s не похоже на адрес s3:…\n' "$key"
          creds_ok=0
        fi
        export "$key=$val" ;;
    esac
  done < "$CREDENTIALS"
fi

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
echo "режим --dry-run: ничего не записано — ни в R2, ни в .env"
if [ "$missing" -gt 0 ] || [ "$missed" != "0" ] || [ "$creds_ok" != "1" ]; then
  exit 1
fi
exit 0
