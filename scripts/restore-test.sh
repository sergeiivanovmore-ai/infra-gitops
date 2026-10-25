#!/bin/bash
# ПРОВЕРКА ВОССТАНОВЛЕНИЯ СЕКРЕТОВ: раз в месяц восстанавливаем последний
# снапшот R2 во временный каталог и убеждаемся, что файлы на месте, права 600 и
# .env не пуст. ТОЛЬКО ЧТЕНИЕ хранилища: живым каталогам ничего не грозит.
#
# Режимы:
#   --inventory  список файлов, которые ожидаются в снапшоте. Ничего не делает.
#   --dry-run    показывает, что и куда будет восстановлено. restic не вызывает.
#   --yes        реальное восстановление во временный каталог + проверки + уборка.
#
# Отчёт в Telegram скрипт не отправляет: он кладёт результат в канал
# «хост -> агент» ($CHANNEL/restore-test.json), доставку делает сторож агента.
# Значения секретов не печатаются ни при каких условиях — только пути, размеры
# и права.
set -euo pipefail

DOCKER_DIR="${BACKUP_DOCKER_DIR:-/opt/docker}"
CREDENTIALS="${BACKUP_CREDENTIALS:-/root/.config/restic/credentials}"
PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/root/.restic-password}"
STATE_TOKEN="${BACKUP_STATE_TOKEN:-/root/.github-agent-state-token}"
AUDIT_TOKEN="${BACKUP_AUDIT_TOKEN:-/root/.github-audit-token}"
CHANNEL="${RESTORE_TEST_CHANNEL:-/opt/docker/hermes-sysadmin/data/logs}"
KEEP="${RESTORE_TEST_KEEP:-0}"

MODE=""
for arg in "$@"; do
  case "$arg" in
    --inventory) MODE="inventory" ;;
    --dry-run)   MODE="dry-run" ;;
    --yes)       MODE="yes" ;;
    *)
      echo "неизвестный аргумент: $arg" >&2
      exit 2 ;;
  esac
done
if [ -z "$MODE" ]; then
  echo "укажите режим: --inventory, --dry-run или --yes" >&2
  exit 2
fi

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

# Ожидаемый состав — тот же обход, что и в scripts/backup-secrets.sh: новый
# агент с каталогом на «hermes» попадёт в проверку сам.
expected=()
covered=""
shopt -s nullglob
for f in "$DOCKER_DIR"/hermes*/data/.env; do
  expected+=("$f")
  covered="$covered $(basename "$(dirname "$(dirname "$f")")")"
done
shopt -u nullglob
expected+=("$DOCKER_DIR/dsh/data/settings.yaml" "$STATE_TOKEN")
[ -f "$AUDIT_TOKEN" ] && expected+=("$AUDIT_TOKEN")

missed=0
for c in "$DOCKER_DIR"/*/data/config.yaml; do
  [ -f "$c" ] || continue
  d="$(basename "$(dirname "$(dirname "$c")")")"
  case " $covered " in
    *" $d "*) continue ;;
  esac
  printf '  %-58s ВНИМАНИЕ: похож на агента, но в состав проверки не попал\n' "$c"
  missed=$((missed + 1))
done

echo "=== ОЖИДАЕМЫЙ СОСТАВ ==="
for f in "${expected[@]}"; do
  printf '  %s\n' "$f"
done
printf 'итого ожидается: %d\n' "${#expected[@]}"

if [ "$MODE" = "inventory" ]; then
  exit 0
fi

TARGET_DIR="/tmp/restore-test-$(date +%Y%m%d-%H%M%S)"

if [ "$MODE" = "dry-run" ]; then
  echo
  echo "=== ПЛАН ==="
  echo "  restic restore <последний снапшот> --target $TARGET_DIR"
  echo "  проверки: файлов ${#expected[@]}, права 600, .env не пуст"
  echo "  уборка:   удаление $TARGET_DIR"
  echo "  результат: $CHANNEL/restore-test.json и строка в stdout"
  echo "режим --dry-run: restic не вызывался, ничего не восстановлено"
  exit 0
fi

# ── --yes ────────────────────────────────────────────────────────────────────
# Уборка за собой — на любом выходе, включая провал проверок. Удаляем только
# свой временный каталог: путь обязан совпадать с ожидаемым шаблоном.
cleanup() {
  case "$TARGET_DIR" in
    /tmp/restore-test-*)
      if [ "$KEEP" = "1" ]; then
        log "уборка: каталог сохранён по RESTORE_TEST_KEEP=1: $TARGET_DIR"
      else
        rm -rf -- "$TARGET_DIR"
        log "уборка: временный каталог удалён"
      fi ;;
    *)
      log "ОСТАНОВ: отказываюсь удалять $TARGET_DIR — путь не похож на временный" ;;
  esac
}
trap cleanup EXIT

fail_with() {  # $1 — причина для отчёта
  local reason="$1"
  log "[P1] restore-test — $reason"
  write_result "P1" "$reason" 0 0 ""
  exit 1
}

write_result() {  # $1 итог, $2 причина, $3 файлов, $4 байт, $5 снапшот
  [ -d "$CHANNEL" ] || mkdir -p "$CHANNEL" 2>/dev/null || return 0
  python3 - "$CHANNEL/restore-test.json" "$1" "$2" "$3" "$4" "$5" <<'PY' 2>/dev/null || true
import json, sys, datetime
path, overall, reason, files, size, snap = sys.argv[1:7]
json.dump({"generated": datetime.datetime.now(datetime.timezone.utc)
           .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
           "overall": overall,
           "reason": reason or None,
           "files": int(files),
           "size_bytes": int(size),
           "snapshot": snap or None},
          open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
}

if ! command -v restic >/dev/null 2>&1; then
  fail_with "restic не найден в PATH"
fi
for f in "$CREDENTIALS" "$PASSWORD_FILE"; do
  if [ ! -f "$f" ]; then
    fail_with "нет файла доступа: $f"
  fi
  m="$(stat -c %a -- "$f")"
  if [ "$m" != "600" ]; then
    log "ОСТАНОВ: $f имеет права $m, ожидалось 600"
    exit 2
  fi
done

# Ключи читаем построчно, НЕ через source: значения содержат знаки $.
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
      export "$key=$val" ;;
  esac
done < "$CREDENTIALS"
export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

SNAP=$(restic snapshots --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
if isinstance(d, list) and d:
    print(d[-1].get("short_id") or d[-1].get("id", ""))
' 2>/dev/null || true)
if [ -z "$SNAP" ]; then
  fail_with "в хранилище нет снапшотов — проверять нечего"
fi
log "восстановление снапшота $SNAP в $TARGET_DIR"

if ! restic restore "$SNAP" --target "$TARGET_DIR"; then
  fail_with "restic restore завершился с ошибкой (снапшот $SNAP)"
fi

problems=0
total=0
checked=0
for f in "${expected[@]}"; do
  r="$TARGET_DIR/${f#/}"
  if [ ! -f "$r" ]; then
    printf '  %-58s НЕТ в снапшоте\n' "$f"
    problems=$((problems + 1))
    continue
  fi
  checked=$((checked + 1))
  size="$(stat -c %s -- "$r")"
  mode="$(stat -c %a -- "$r")"
  total=$((total + size))
  printf '  %-58s %8s Б  права %s\n' "$f" "$size" "$mode"
  if [ "$mode" != "600" ]; then
    problems=$((problems + 1))
    continue
  fi
  case "$f" in
    *.env)
      if [ ! -s "$r" ]; then
        printf '  %-58s пустой .env — восстановление бессмысленно\n' "$f"
        problems=$((problems + 1))
      fi ;;
  esac
done

# Файл пароля и файл ключей не должны попасть в снапшот ни при каких
# обстоятельствах: если они там окажутся, значит бэкап забирает не то, и это
# опаснее любого расхождения прав.
leaked=$(find "$TARGET_DIR" -type f \( -name 'restic-password' -o -name 'credentials' \) 2>/dev/null | head -3)
if [ -n "$leaked" ]; then
  printf '  ВНИМАНИЕ: в снапшоте оказались файлы доступа:\n%s\n' "$leaked"
  problems=$((problems + 1))
fi

size_kb=$((total / 1024))
if [ "$problems" -gt 0 ] || [ "$missed" != "0" ]; then
  reason_tail=""
  [ "$problems" -gt 0 ] && reason_tail="проблем: $problems из ${#expected[@]}"
  [ "$missed" != "0" ] && reason_tail="$reason_tail (агентов вне проверки: $missed)"
  log "[P1] restore-test — восстановление дало проблемы: $reason_tail"
  write_result "P1" "восстановление дало проблемы: $reason_tail" \
    "$checked" "$total" "$SNAP"
  exit 1
fi

log "[OK] restore-test — ${#expected[@]} файлов, mode 600, размер $size_kb KB (снапшот $SNAP)"
write_result "OK" "" "$checked" "$total" "$SNAP"
exit 0
