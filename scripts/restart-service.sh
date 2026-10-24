#!/bin/bash
# Перезапуск одного контейнера по декларативной заявке из outbox агента.
#
# ЗАЧЕМ: агенту нужен перезапуск сервиса, но прямой доступ к docker-сокету
# закрыт (POST=0, ALLOW_RESTARTS=0). Команда запускается на хосте от root,
# а подтверждение приходит не аргументом, а смерженным файлом approvals/:
# у агента нет инструмента для запуска workflow, подделать подтверждение нельзя.
#
# ЗАЯВКА: outbox/run/restart-service.sh, содержимое — имя контейнера.
# Публикатор запускает scripts/restart-service.sh с аргументом --yes только
# тогда, когда в main лежит approvals/restart-service.sh, sha256 которого
# совпадает с sha256 самого скрипта. Без --yes включён режим плана.
#
# ГРАНИЦА, ЗАШИТАЯ В КОД: имя сверяется с ALLOWLIST по точному совпадению.
# Никакой другой контейнер перезапустить нельзя, даже если его имя попадёт
# в заявку. nginx-proxy и mail-relay отсутствуют намеренно: пересоздание
# ingress роняет все домены, перезапуск почты теряет письма. hermes-sysadmin
# тоже исключён — это завершило бы сессию самого агента.
#
# ИДЕМПОТЕНТНОСТЬ: скрипт без состояния. Повторный запуск на работающем
# контейнере безвреден, отсутствующий контейнер — отказ без действий.
# Заявка одноразовая: публикатор переносит её в outbox/sent/run/ с кодом
# возврата в имени, поэтому для нового перезапуска нужна новая заявка.
set -u

OUTBOX=/opt/docker/hermes-sysadmin/data/workspace/outbox
REQ="$OUTBOX/run/restart-service.sh"
LOGDIR=/opt/docker/hermes-sysadmin/data/logs
LOG="$LOGDIR/restart-service.log"
MAXLEN=64
YES="${1:-}"

ALLOWLIST="hermes-gateway hermes-work hermes-orchestrator hermes-studio dsh design-site-nginx"

say() {
  echo "$*"
  echo "[$(date -Iseconds)] $*" >> "$LOG" 2>/dev/null || true
}

if [ "$YES" = "--yes" ]; then
  say "старт: режим применения (подтверждение человеком)"
else
  say "старт: режим плана (изменений не будет)"
fi

[ -d "$LOGDIR" ] || say "предупреждение: нет каталога логов $LOGDIR, запись в лог недоступна"

if [ ! -f "$REQ" ]; then
  say "заявки нет ($REQ) — действий не требуется"
  exit 0
fi

target=$(tr -d ' \t\r\n' < "$REQ" 2>/dev/null || echo "")

if [ -z "$target" ]; then
  say "ОТКАЗ: заявка пустая — действий нет"
  exit 2
fi

if [ "${#target}" -gt "$MAXLEN" ]; then
  say "ОТКАЗ: имя длиннее $MAXLEN символов — действий нет"
  exit 2
fi

case "$target" in
  *[!A-Za-z0-9._-]*)
    say "ОТКАЗ: недопустимые символы в имени '$target' — действий нет"
    exit 2
    ;;
esac

case " $ALLOWLIST " in
  *" $target "*) : ;;
  *)
    say "ОТКАЗ: '$target' отсутствует в allowlist — действий нет"
    exit 2
    ;;
esac

status=$(docker inspect "$target" --format '{{.State.Status}}' 2>/dev/null || echo "")
if [ -z "$status" ]; then
  say "ОТКАЗ: контейнер '$target' не найден — действий нет"
  exit 2
fi

if [ "$YES" != "--yes" ]; then
  say "ПЛАН: перезапустил бы '$target' (сейчас: $status)."
  say "ПЛАН: для применения нужен approvals/restart-service.sh со совпавшим sha256 скрипта."
  exit 0
fi

say "ПРИМЕНЕНИЕ: docker restart '$target' (состояние до: $status)"
docker restart "$target"
rc=$?
after=$(docker inspect "$target" --format '{{.State.Status}}' 2>/dev/null || echo "неизвестно")
say "DONE: '$target' — rc=$rc, состояние после: $after"
exit "$rc"
