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

# --- сходимость сайта: прод = main репозитория сайта ------------------------
# Живой сайт отдаёт файлы из /opt/docker/jt-design-site, поэтому развёртывание
# = приведение этой папки к содержимому src/ из main репозитория сайта.
# Скрипт сам проверяет, что его код подтверждён владельцем
# (approvals/deploy-site-prod.sh); без подтверждения он не делает ничего.
# Ошибка сходимости исход деплоя не меняет.
SITE_SYNC=/opt/infra-gitops/scripts/deploy-site-prod.sh
if [ -f "$SITE_SYNC" ]; then
  say "[$TS] -- сходимость сайта (прод = main репозитория сайта) --"
  if timeout 600 bash "$SITE_SYNC"; then
    say "[$TS] -- сайт: сходимость завершена --"
  else
    say "[$TS] -- сайт: сходимость завершилась с ошибкой (деплой не затронут) --"
  fi
else
  say "[$TS] -- сайт: $SITE_SYNC не найден, пропуск --"
fi

# --- модели агентов из agents/*/models.yaml --------------------------------
# Файлы-оверрайды лежат в репозитории; скрипт меняет только ключи модели и
# провайдера, делает копию конфига и перезапускает агента лишь при изменении.
MODELS_APPLY=/opt/infra-gitops/scripts/apply-agent-models.sh
if [ -f "$MODELS_APPLY" ]; then
  say "[$TS] -- модели агентов из GitOps --"
  if timeout 300 bash "$MODELS_APPLY"; then
    say "[$TS] -- модели применены --"
  else
    say "[$TS] -- применение моделей завершилось с ошибкой (деплой не затронут) --"
  fi
else
  say "[$TS] -- $MODELS_APPLY не найден, пропуск --"
fi

# --- наложение оверрайдов настроек agents/*/settings/*.yaml ----------------
SETTINGS_APPLY=/opt/infra-gitops/scripts/apply-agent-settings.sh
if [ -f "$SETTINGS_APPLY" ]; then
  say "[$TS] -- наложение оверрайдов настроек --"
  if timeout 300 bash "$SETTINGS_APPLY"; then
    say "[$TS] -- наложение оверрайдов завершено --"
  else
    say "[$TS] -- наложение оверрайдов завершилось с ошибкой (деплой не затронут) --"
  fi
else
  say "[$TS] -- $SETTINGS_APPLY не найден, пропуск --"
fi
# --- владелец и права конфигов после каждой записи -------------------------
# Деплой копирует конфиги через cp от root, после чего контейнер, работающий
# от своего uid, больше не может их прочитать. Идемпотентно; запускается и вручную.
OWNERS=/opt/infra-gitops/scripts/fix-config-owners.sh
if [ -f "$OWNERS" ]; then
  say "[$TS] -- владелец и права конфигов --"
  if timeout 120 bash "$OWNERS"; then
    say "[$TS] -- владелец и права конфигов выставлены --"
  else
    say "[$TS] -- шаг с правами конфигов не удался (деплой не затронут) --"
  fi
else
  say "[$TS] -- $OWNERS не найден, пропуск --"
fi

# --- проверка здоровья VPS -------------------------------------------------
# Отчёт пишется в канал «хост -> агент»; код возврата делает красный прогон
# независимым каналом оповещения (не зависит от того, жив ли агент).
HEALTH=/opt/infra-gitops/scripts/health-check.sh
HEALTH_RC=0
if [ -f "$HEALTH" ]; then
  say "[$TS] -- здоровье VPS --"
  bash "$HEALTH" --install-cron || true
  bash "$HEALTH" || HEALTH_RC=$?
  if [ "$HEALTH_RC" -ne 0 ]; then
    say "[$TS] -- здоровье: есть отклонения P1/CI (код $HEALTH_RC) --"
  else
    say "[$TS] -- здоровье: в норме --"
  fi
else
  say "[$TS] -- $HEALTH не найден, пропуск --"
fi

# ── Права на конфиги после перезапуска агентов ───────────────────────────────
# Hermes при старте мигрирует config.yaml и пишет его от uid агента с umask 027,
# из-за чего файл становится 640 вместо 600. Вызов fix-config-owners.sh выше по
# тексту отрабатывает ДО миграции: по замеру на хосте разрыв составил 55 секунд.
# Поэтому здесь второй проход, причём не с фиксированной паузой, а с добором:
# проверяем, что права вернулись, и повторяем, пока не вернутся или не кончится
# запас времени.
#
# Учитываются ТОЛЬКО те конфиги, которые реально ведёт fix-config-owners.sh.
# Конфиги gateway, orchestrator и work в него не заведены: их агенты запущены под
# root, поэтому 640 для них не поломка, а норма. Расширение списка целей —
# отдельная задача; включать сюда необрабатываемые файлы нельзя, иначе проверка
# всегда будет считать, что права не вернулись.
OwnedFiles="/opt/docker/hermes-sysadmin/data/config.yaml /opt/docker/dsh/data/settings.yaml"
if [ -f "$OWNERS" ]; then
  sleep 15
  for attempt in 1 2 3 4 5 6; do
    if ! bash "$OWNERS"; then
      echo "WARN: fix-config-owners.sh вернул ошибку (попытка $attempt)" >&2
    fi
    # Пусто — значит ни у одного из ведомых конфигов нет прав для группы или
    # прочих, то есть миграция уже прошла и повторять нечего.
    if [ -z "$(find $OwnedFiles -maxdepth 0 -perm /077 2>/dev/null)" ]; then
      echo "  owners: права на конфиги в порядке (попытка $attempt)"
      break
    fi
    if [ "$attempt" = "6" ]; then
      echo "WARN: права на конфиги всё ещё ослаблены после 90 секунд ожидания" >&2
      break
    fi
    sleep 15
  done
else
  echo "WARN: нет $OWNERS — права на конфиги не подтверждены" >&2
fi

exit "$HEALTH_RC"
