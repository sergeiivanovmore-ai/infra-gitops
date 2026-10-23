#!/bin/bash
# Входная точка хостового шага ops-publish: след запуска, проверки, запуск.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ: логика в YAML невидима агенту (логи Actions ему закрыты
# даже на публичном репозитории), не проходит ревью как код и не проверяется
# линтером. Здесь она версионируется, читается и проверяется. Сам workflow
# остаётся одной строкой — ровно как у деплоя, который работает.
#
# ПОДТВЕРЖДЕНИЕ ПРИМЕНЕНИЯ. Аргумент из workflow до хоста не доходит: ключ
# на хосте закреплён за деплоем (command="sudo /usr/local/bin/deploy-infra.sh"),
# то есть строка запуска подменяется целиком вместе с аргументами. Поэтому
# рабочий канал подтверждения ровно один — смерженный файл в репозитории:
# approvals/<имя скрипта> содержит sha256 самого scripts/<имя>. Подтверждение
# привязано к отпечатку исполняемого кода: изменится скрипт — подтверждение
# перестанет совпадать. Человек-единственный, кто может создать такой файл:
# запись в main идёт только через PR.
set -u

LOGDIR=/opt/docker/hermes-sysadmin/data/logs
TRACE="${LOGDIR}/ops-publish-boot.log"
PUBLISHER=/opt/infra-gitops/scripts/ops-publish.sh
OUTBOX=/opt/docker/hermes-sysadmin/data/workspace/outbox/run
APPROVALS=/opt/infra-gitops/approvals
SCRIPTS=/opt/infra-gitops/scripts
APPROVE="${1:-}"

# След идёт ДВУМЯ путями: в лог, который агент читает локально, и в вывод шага.
# Если прав на запись нет, вывод шага всё равно расскажет, что именно не так, —
# ровно этого не хватало при первом разборе, когда шаг «успешен», а на хосте
# ничего не произошло.
say() {
  echo "$*"
  echo "$*" >> "$TRACE" 2>/dev/null || echo "(след в $TRACE записать не удалось)"
}

TS=$(date -Iseconds)
say "[$TS] шаг начался: user=$(id -un), uid=$(id -u), pwd=$(pwd)"

# Подтверждение из аргумента: только имя скрипта, ничего больше.
case "$APPROVE" in
  "") : ;;
  *[!A-Za-z0-9._-]*) say "[$TS] подтверждение отклонено: недопустимые символы, остаёмся в режиме плана"; APPROVE="" ;;
esac

# Рабочий канал: файл подтверждения в репозитории. Ищем approvals/*, для каждого
# требуем наличие заявки в outbox и совпадение sha256 с исполняемым скриптом.
if [ -z "$APPROVE" ] && [ -d "$APPROVALS" ]; then
  for a in "$APPROVALS"/*; do
    [ -f "$a" ] || continue
    name=$(basename "$a")
    case "$name" in
      *[!A-Za-z0-9._-]*) say "[$TS] approvals/$name: недопустимое имя — пропуск"; continue ;;
    esac
    if [ ! -f "$OUTBOX/$name" ]; then
      say "[$TS] approvals/$name: заявки нет в outbox — пропуск"
      continue
    fi
    if [ ! -f "$SCRIPTS/$name" ]; then
      say "[$TS] approvals/$name: нет scripts/$name — пропуск"
      continue
    fi
    want=$(tr -d ' \t\r\n' < "$a")
    have=$(sha256sum "$SCRIPTS/$name" | cut -d' ' -f1)
    if [ -n "$want" ] && [ "$want" = "$have" ]; then
      APPROVE="$name"
      say "[$TS] подтверждение принято: approvals/$name совпал с sha256(scripts/$name)"
      break
    fi
    say "[$TS] approvals/$name не совпал по отпечатку — для него режим плана"
  done
fi

if [ -n "$APPROVE" ]; then
  say "[$TS] человек подтвердил применение: $APPROVE"
else
  say "[$TS] режим: план (изменений не будет)"
  if [ -d "$OUTBOX" ]; then
    for f in "$OUTBOX"/*; do
      [ -f "$f" ] || continue
      nm=$(basename "$f")
      [ -f "$SCRIPTS/$nm" ] || continue
      say "[$TS] для применения '$nm' нужен файл approvals/$nm со строкой: $(sha256sum "$SCRIPTS/$nm" | cut -d' ' -f1)"
    done
  fi
fi

# Диагностика среды: без этих строк разбор упирается в догадки.
[ -d "$LOGDIR" ] || say "[$TS] каталог логов не найден: $LOGDIR"
[ -w "$LOGDIR" ] || say "[$TS] нет прав на запись в $LOGDIR — проверь пользователя ssh"
[ -d /opt/infra-gitops ] || say "[$TS] нет каталога /opt/infra-gitops"

if [ -f "$PUBLISHER" ]; then
  say "[$TS] публикатор найден ($(wc -c < "$PUBLISHER") байт), запускаю"
  OPS_APPROVE="$APPROVE" bash "$PUBLISHER"
  RC=$?
  say "[$TS] публикатор завершён rc=$RC"
else
  say "[$TS] ПРОПУСК: $PUBLISHER не найден"
  say "[$TS] что есть рядом:"
  ls -la /opt/infra-gitops 2>&1 | head -15
  ls -la /opt/infra-gitops/scripts 2>&1 | head -25
fi
