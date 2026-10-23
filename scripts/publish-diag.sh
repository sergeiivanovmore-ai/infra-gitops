#!/bin/bash
# Диагностика на хосте + публикация отчёта в ветку reports/diag.
# Запускается workflow'ом diagnose.yml через appleboy/ssh-action от root.
# Публикует ХОСТ: у хостового клона есть рабочий SSH-доступ к GitHub
# (им же деплой делает git fetch), это единственный проверенный компонент.
# Working tree деплойного клона не трогаем — используем worktree.
# Код возврата всегда 0: за корректность отвечает проверка в workflow.
set -u

REPO="/opt/infra-gitops"
REPORT="/opt/docker/hermes-sysadmin/data/logs/diag-last.md"
WT="/tmp/diag-publish"

if [ ! -f "$REPO/scripts/diagnose-infra.sh" ]; then
  echo "ERROR: нет $REPO/scripts/diagnose-infra.sh — клон не обновлён" >&2
  exit 1
fi

if bash "$REPO/scripts/diagnose-infra.sh" > /tmp/diag-run.log 2>&1; then
  echo "диагностика: тревог нет"
else
  echo "диагностика: есть тревоги"
fi

if [ ! -s "$REPORT" ]; then
  echo "ERROR: отчёт не создан: $REPORT" >&2
  exit 1
fi

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "WARN: $REPO не git-репозиторий — публикация пропущена"
  exit 0
fi

rm -rf "$WT"
if ! git -C "$REPO" worktree add -f --detach "$WT" >/dev/null 2>&1; then
  echo "ERROR: worktree не создан ($WT)" >&2
  exit 1
fi

mkdir -p "$WT/reports"
cp -f "$REPORT" "$WT/reports/latest.md"
if git -C "$WT" add -f reports/latest.md \
   && git -C "$WT" -c user.name=infra-report \
        -c user.email=infra-report@users.noreply.github.com \
        commit -q -m "diag: отчёт $(date -Iseconds)" \
   && git -C "$WT" push -q -f origin HEAD:reports/diag; then
  echo "публикация: ветка reports/diag обновлена"
else
  echo "ERROR: публикация не удалась (git rc != 0)" >&2
fi
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true

echo "локальная копия: $REPORT"
exit 0