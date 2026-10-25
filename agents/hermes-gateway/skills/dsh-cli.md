---
name: dsh-cli
description: Запуск задач через DSH headless CLI вместо несовместимого MCP bridge
---

# Использование DSH через CLI

Для сложных задач (код, файлы, исследования, веб-обзоры) используй **DSH headless** через terminal tool.

## Команда

docker exec dsh dsh --profile headless "ЗАДАЧА"

## Когда использовать

- Пользователь явно просит "через DSH" / "через DeepSeek Harness"
- Многошаговые кодовые задачи
- Работа с файлами в DSH workspace
- Веб-исследования

## НЕ использовать

- mcp__dsh__agent_run - несовместим с DSH 0.1.5-rc.3, возвращает ошибку encodeCurrent requires Session format v3
- mcp__dsh__task_inbox - та же проблема

## Таймаут

DSH-задачи занимают 30 секунд - 5 минут. Ставь timeout не менее 300000 мс.

## Возврат

- stdout: финальный ответ агента
- stderr: reasoning (можно игнорировать)

## Примеры

Запрос: "Найди тренды освещения 2026 через DSH"
Команда: docker exec dsh dsh --profile headless "Найди в интернете тренды освещения квартир 2026 и сделай обзор"

Запрос: "Создай скрипт бэкапа через DSH"
Команда: docker exec dsh dsh --profile headless "Напиши bash-скрипт бэкапа /opt в /home/dsh/workspace/backup.sh"
