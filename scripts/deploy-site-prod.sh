#!/bin/bash
# Сходимость прода сайта jt-design к состоянию main репозитория сайта.
#
# ВАРИАНТ А (согласован с владельцем): живой сайт отдаёт контейнер
# design-site-nginx, у которого каталог /opt/docker/jt-design-site примонтирован
# в /usr/share/nginx/html (ro). Значит развёртывание = привести этот каталог к
# содержимому src/ из main репозитория сайта. Ничего не пересоздаётся и из
# реестра образов ничего не тянется.
#
# ИСТОЧНИК ПРАВДЫ: main репозитория sergeiivanovmore-ai/jt-design-hermes-site.
# На прод попадает ровно тот коммит, который лежит в main, то есть прошедший
# ревью и мерж человеком. Отдельного подтверждения на каждую версию не нужно:
# согласованием служит сам мерж.
#
# ГРАНИЦЫ: владелец подтверждает код ЭТОГО скрипта один раз (файл
# approvals/deploy-site-prod.sh с его sha256). Без совпадения отпечатка скрипт
# отказывается что-либо делать — fail closed, как у остальных деструктивных
# операций на этом хосте.
#
# Никакого rsync --delete: rsync по /opt/docker запрещён правилами. Удаление
# лишних файлов делается явным шагом с перечислением в логе.
set -u

SITE_REPO=sergeiivanovmore-ai/jt-design-hermes-site
TARGET=/opt/docker/jt-design-site
BACKUP_ROOT=/opt/docker/jt-design-site.backups
BACKUP_KEEP=3
APPROVAL=/opt/infra-gitops/approvals/deploy-site-prod.sh
SELF=/opt/infra-gitops/scripts/deploy-site-prod.sh
URL=https://jt-design.ru/
MODE=apply
[ "${1:-}" = "--dry-run" ] && MODE=dry

say() { echo "[site-deploy] $*"; }
fail() { echo "[site-deploy] ОТКАЗ: $*" >&2; exit 0; }

[ "$(id -u)" = "0" ] || fail "нужен root"
command -v git >/dev/null 2>&1 || fail "нет git"
command -v curl >/dev/null 2>&1 || fail "нет curl"

# --- 1. подтверждение кода -------------------------------------------------
if [ ! -f "$APPROVAL" ]; then
  fail "нет файла подтверждения $APPROVAL — сходимость не применяется"
fi
if [ ! -f "$SELF" ]; then
  fail "не найден сам скрипт $SELF"
fi
want=$(tr -d ' \t\r\n' < "$APPROVAL")
have=$(sha256sum "$SELF" | cut -d' ' -f1)
if [ -z "$want" ] || [ "$want" != "$have" ]; then
  fail "отпечаток подтверждения не совпал с кодом скрипта (ожидался $have)"
fi
say "подтверждение принято: approvals/deploy-site-prod.sh совпал с sha256 кода"

# --- 2. целевой коммит ----------------------------------------------------
SHA=$(timeout 60 git ls-remote "https://github.com/$SITE_REPO.git" refs/heads/main 2>/dev/null | cut -f1)
case "$SHA" in
  [0-9a-f][0-9a-f][0-9a-f]*) : ;;
  *) fail "не удалось получить вершину main репозитория $SITE_REPO" ;;
esac
say "цель: main = $SHA"

# --- 3. забрать архив с этим коммитом ------------------------------------
TMP=$(mktemp -d /tmp/site-deploy.XXXXXX) || fail "не создать временный каталог"
trap 'rm -rf "$TMP"' EXIT
if ! timeout 180 curl -sSL -o "$TMP/site.tar.gz" "https://codeload.github.com/$SITE_REPO/tar.gz/$SHA"; then
  fail "не скачать архив репозитория"
fi
if ! tar -xzf "$TMP/site.tar.gz" -C "$TMP" 2>/dev/null; then
  fail "не распаковать архив"
fi
SRC=$(find "$TMP" -maxdepth 2 -type d -name src | head -1)
[ -n "$SRC" ] || fail "в архиве нет каталога src"
say "источник распакован: $(find "$SRC" -type f | wc -l) файлов"

# --- 4. сравнить содержимое ----------------------------------------------
manifest() {
  local root="$1"
  ( cd "$root" && find . -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1 )
}
src_manifest=$(manifest "$SRC")
[ -d "$TARGET" ] || fail "нет целевого каталога $TARGET"
dst_manifest=$(manifest "$TARGET")
if [ "$src_manifest" = "$dst_manifest" ]; then
  say "содержимое уже соответствует main — изменений не требуется"
  exit 0
fi
say "содержимое отличается: обновление требуется"
if [ "$MODE" = dry ]; then
  say "режим плана: изменения не вносились"
  exit 0
fi

# --- 5. резервная копия ---------------------------------------------------
ts=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_ROOT"
if ! cp -a "$TARGET" "$BACKUP_ROOT/$ts"; then
  fail "не сделать резервную копию — обновление отменено"
fi
say "резервная копия: $BACKUP_ROOT/$ts"
ls -1dt "$BACKUP_ROOT"/* 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | while read -r old; do
  [ -n "$old" ] && rm -rf "$old" && say "удалена старая копия: $(basename "$old")"
done

# --- 6. перенести файлы ---------------------------------------------------
if ! cp -a "$SRC"/. "$TARGET"/; then
  say "ошибка копирования — восстанавливаю из резервной копии"
  cp -a "$BACKUP_ROOT/$ts"/. "$TARGET"/ && say "прежнее содержимое восстановлено"
  exit 1
fi
say "файлы перенесены"

# --- 7. удалить лишнее (явным шагом, с перечислением) ---------------------
removed=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in ./*) : ;; *) continue ;; esac
  if [ ! -e "$SRC/$rel" ]; then
    rm -f "$TARGET/$rel" && say "  удалён лишний файл: ${rel#./}"
    removed=$((removed+1))
  fi
done < <(cd "$TARGET" && find . -type f)
find "$TARGET" -type d -empty -delete 2>/dev/null || true
say "лишних файлов удалено: $removed"

# --- 8. проверка результата ----------------------------------------------
new_manifest=$(manifest "$TARGET")
if [ "$new_manifest" != "$src_manifest" ]; then
  say "содержимое не совпало с источником — восстанавливаю"
  cp -a "$BACKUP_ROOT/$ts"/. "$TARGET"/ && say "прежнее содержимое восстановлено"
  exit 1
fi
local_size=$(stat -c %s "$TARGET/index.html" 2>/dev/null || echo 0)
read -r code size < <(timeout 30 curl -sS -o /dev/null -w '%{http_code} %{size_download}' "$URL" 2>/dev/null || echo "000 0")
say "проверка сайта: http=$code size=$size локальный index.html=$local_size"
if [ "$code" != "200" ] || [ "$size" != "$local_size" ]; then
  say "сайт отдаёт не то, что развернули — восстанавливаю прежнюю версию"
  cp -a "$BACKUP_ROOT/$ts"/. "$TARGET"/ && say "прежнее содержимое восстановлено"
  exit 1
fi
say "готово: прод соответствует main ($SHA), сайт отвечает 200 размером $size"
say "диск: $(df -h / | awk 'NR==2 {print $3" занято, "$4" свободно"}')"
exit 0