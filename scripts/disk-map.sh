#!/bin/bash
# Карта диска: где на хосте лежат гигабайты. Только чтение, ничего не удаляет.
#
# ЗАЧЕМ: раздел про диск в diagnose-infra.sh смотрит только /opt/docker, а большая
# часть диска занята вне него (/var/lib/docker, логи, home). Без цифр «где именно»
# любое решение про чистку — гадание. Запускается через канал заявок публикатора
# (outbox/run/disk-map.sh); вывод целиком попадает в logs/ops-run-disk-map.log,
# который агент читает локально.
#
# БЕЗОПАСНОСТЬ: скрипт read-only — не пишет, не удаляет, не останавливает
# контейнеры. Ни одной операции с аргументами: параметров нет вовсе. Все тяжёлые
# обходы под timeout. В вывод идут только пути, размеры и счётчики; содержимое
# файлов и значения переменных окружения не печатаются.
set -u

T=${DISK_MAP_TIMEOUT:-60}
run() { timeout "$T" bash -c "$1" 2>&1 || echo "(прервано: timeout ${T}s или ошибка)"; }
sec() { echo; echo "===== $* ====="; }

sec "когда и где"
echo "дата: $(date -Iseconds)"
echo "хост: $(hostname), ядро: $(uname -r)"
echo "docker: $(docker --version 2>/dev/null || echo 'не найден')"

sec "файловые системы"
run "df -h -x tmpfs -x devtmpfs -x squashfs | head -12"
run "df -i / | tail -2"

sec "верхний уровень корня"
run "du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -15"

sec "внутри /var, /opt, /home, /root"
run "du -xh --max-depth=2 /var /opt /home /root 2>/dev/null | sort -h | tail -25"

sec "docker: сводка по занятому месту"
run "docker system df 2>/dev/null"
run "docker system df -v 2>/dev/null | head -40"

sec "docker: json-логи контейнеров больше 50 МБ"
run "find /var/lib/docker/containers -name '*-json.log' -size +50M -printf '%k КБ\t%p\n' 2>/dev/null | sort -n | tail -20"

sec "journald"
run "journalctl --disk-usage 2>/dev/null || echo 'journalctl недоступен'"

sec "крупнейшие файлы больше 1 ГБ вне /opt/docker"
run "find / -xdev -type f -size +1G -not -path '/opt/docker/*' -not -path '/proc/*' -printf '%k КБ\t%p\n' 2>/dev/null | sort -n | tail -20"

sec "для сверки: /opt/docker по каталогам"
run "du -xh --max-depth=1 /opt/docker 2>/dev/null | sort -h | tail -15"

sec "готово"
echo "изменений не вносилось, ничего не удалялось"