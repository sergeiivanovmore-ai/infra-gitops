---
name: dsh-agent
description: "DSH (DeepSeek Harness) через MCP dsh-carrot — запуск кода, файлы, веб-поиск"
version: 6.1.0
platforms: [linux]
metadata:
  hermes:
    tags: [dsh, deepseek, harness, mcp, agent, code]
    related_skills: []
---

# DSH через MCP dsh-carrot

DSH — это **автономный агент-исполнитель** в отдельном контейнере.
Он умеет: bash, работа с файлами, веб-поиск, написание и запуск кода.

Hermes = мозг (планирование), DSH = руки (выполнение).

## Основное правило

**ОДИН вызов `agent_run` → дождаться результата → ответить.**

НЕ отменять. НЕ дублировать. НЕ запускать параллельно с `searxng`/`browser`.

## Основной инструмент

### `mcp__dsh_carrot__agent_run`

Параметры:
- `task` (обязательно) — полное описание задачи **одним текстом**
- `cwd` (опционально) — рабочая директория. **Всегда** `/home/dsh/workspace`
- `sessionId` (опционально) — для продолжения существующей сессии
- `provider` / `model` (опционально) — конкретная модель для этой задачи
- `detail` (опционально) — `brief` / `full`

Примеры:

Простая задача:
mcp__dsh_carrot__agent_run(
task="Создай файл /home/dsh/workspace/hello.py со скриптом print('hi') и запусти его",
cwd="/home/dsh/workspace"
)

text

Веб-исследование:
mcp__dsh_carrot__agent_run(
task="Найди в интернете 3 тренда автоматизации VPS на 2026, кратко 5 предложений с источниками",
cwd="/home/dsh/workspace"
)

text

Продолжение сессии (тот же контекст):
mcp__dsh_carrot__agent_run(
task="Добавь ещё 2 тренда",
cwd="/home/dsh/workspace",
sessionId="abc123-..."
)

text

Дешёвая модель для простой задачи:
mcp_dsh_carrot__agent_run(
task="Посчитай факториал 100",
cwd="/home/dsh/workspace",
provider="openrouter",
model="inclusionai/ling-2.6-flash"
)

text

⚠️ **Всегда указывай `provider`+`model` явно.** Дефолтная модель
`openrouter/nvidia/nemotron-3-ultra-550b-a55b:free` регулярно перегружена —
именно она даёт `Upstream error from Nvidia` и таймауты 600с.
Проверенный надёжный fallback: `provider="openrouter"`, `model="deepseek/deepseek-v4-flash"`.
Список моделей: `model_list`. Подробности — `references/dsh-model-fallbacks.md`.

## Асинхронные задачи (только если > 5 минут)

Если задача **заведомо долгая** (анализ большого репозитория, массовые операции):
mcp__dsh_carrot__task_inbox(task="...", cwd="/home/dsh/workspace")
→ возвращает taskId

Подожди 60 секунд

mcp__dsh_carrot__task_result(taskId="...", detail="status")

Если done — забрать результат

Если running — подождать ещё

text

**Не используй `task_inbox` для коротких задач** — это лишние итерации.

## Дополнительные инструменты

| Инструмент | Когда |
|------------|-------|
| `echo` | Проверка связи с DSH |
| `session_list` | Посмотреть существующие сессии |
| `session_history(sessionId=...)` | История конкретной сессии |
| `model_list` | Список доступных моделей |
| `select_model(sessionId=..., model=...)` | Сменить модель в сессии |
| `task_cancel(taskId=...)` | Отменить зависшую задачу (редко) |

## СТРОГО НЕ ИСПОЛЬЗОВАТЬ

- ❌ `mcp__dsh__agent_run`, `mcp__dsh__task_inbox` — **старый bridge, сломан** (encodeCurrent requires Session format v3)
- ❌ `mcp_searxng_search_*` для DSH-задач — DSH сам ищет в интернете
- ❌ `browser_navigate` — браузера в Hermes нет, он в DSH
- ❌ `terminal` с `docker exec dsh` — DSH в отдельном контейнере, недоступен из Hermes
- ❌ `which dsh`, `find / -name dsh` — бинарник DSH не в Hermes

## Timeout и ожидание

- **Timeout MCP:** 600 секунд (10 минут) — жёсткий лимит, после которого обрывается
- **Типичное время ответа:** 30 секунд — 3 минуты
- **Если > 5 минут** — используй `task_inbox`
- **НЕ отменяй задачу** через 30 секунд — она ещё работает

## Рабочая директория**НЕ отменяй задачу** через 30 секунд — она ещё работает

## Рабочая директория

DSH видит файлы **только в `/home/dsh/workspace/`** (bind-mount).
- На хосте это `/opt/docker/dsh/workspace/`
- Логи, конфиги DSH: `/home/dsh/.dsh/`
- **НЕ пиши в `/tmp`** — потеряется при перезапуске
- **НЕ пиши в `/opt/dsh`** — это временная папка DSH

## Известные проблемы

> ⚠️ Старый файл `references/dsh-timeout-issue-2025-09.md` содержал вывод «DSH сломан, используй локальные инструменты» — он **устарел и неверен**. Реальная причина была в перегруженной модели. Актуальные находки: `references/dsh-model-fallbacks.md`.

### ⚠️ `agent_run` висит до таймаута 600с — как правило, из-за перегруженной модели
Симптомы: `TimeoutError: MCP call timed out after 600.0s` ИЛИ
`PI_AI_ERROR: Upstream error from Nvidia: Service temporarily overloaded`.
**Причина (проверено):** дефолтная модель `openrouter/nvidia/nemotron-3-ultra-550b-a55b:free`
перегружена. Сам `agent_run` при этом **работает** — не бросай DSH.
**Fix:** задай `provider="openrouter"` + `model="deepseek/deepseek-v4-flash"`.
С этой моделью `agent_run` выполняет bash/файлы и возвращает результат за секунды.

### ⚠️ Сессия на «мёртвой» модели залипает
Если один раз запустил сессию на перегруженной модели, последующие вызовы в тот же
cwd/session могут висеть. Лечение: новый `cwd` (свежая сессия), явный `provider`/`model`,
либо `sessionId` гарантированно рабочей сессии.

### ⚠️ `task_inbox` может застрять в статусе `queued`
Наблюдалось: задача висит в `queued` 3+ минут, пока воркер занят зависшей сессией.
**Workaround:** `task_cancel(taskId)` → перейти на синхронный `agent_run` с рабочей моделью.

### ⚠️ Провайдер `deepseek-official` не принимается
Возвращает `MISSING_CREDENTIAL: no API key for provider route "deepseek-official"`.
**Workaround:** используй `openrouter` + `deepseek/deepseek-v4-flash`.

### ✅ Работающие инструменты
- `model_list` — мгновенно
- `session_list` — работает
- `echo` — работает (проверка связи)
- `agent_run` с рабочей моделью — работает (bash, файлы, веб)

### 🔧 Fallback-паттерны
| Ситуация | Действие |
|----------|----------|
| `agent_run` висит / таймаут | смени модель: `openrouter` + `deepseek/deepseek-v4-flash` |
| Нужен список моделей | `model_list` |
| DSH реально `unreachable` (MCP мёртв) | только тогда локальные `execute_code` / `file` |

### Рекомендуемый паттерн при сбое DSH
1. Попробуй `echo` — если отвечает, MCP соединение живо
2. Попробуй `model_list` — если работает, API функционирует
3. **Сначала смени модель:** повтори `agent_run` с `provider="openrouter"` + `model="deepseek/deepseek-v4-flash"`. В большинстве случаев этого достаточно.
4. Только если DSH реально `unreachable` — переключайся на локальные инструменты (`execute_code`, `file`)
5. Отчитывайся коротко и на русском

## Обработка ошибок

| Ошибка | Что делать |
|--------|-----------|
| `MCP call timed out` | Скажи: "Задача превысила timeout. Увеличьте timeout в config.yaml." |
| `Session terminated` | Пропусти, Hermes сам переподключится |
| `Cannot find module` | Скажи пользователю — нужна помощь администратора |
| `Host not allowed` | Ошибка конфига DSH, скажи пользователю |

## Примеры задач по типу

### Код
- "Создай скрипт X в /home/dsh/workspace/"
- "Проанализируй код в /home/dsh/workspace/project/"
- "Запусти тесты в /home/dsh/workspace/"

### Данные
- "Найди в интернете X и собери отчёт в /home/dsh/workspace/report.md"
- "Спарси сайт Y и сохрани данные"

### Файлы
- "Найди все файлы *.py в /home/dsh/workspace/"
- "Переименуй файлы в /home/dsh/workspace/old/"

### Система
- "Проверь свободное место на диске"
- "Покажи топ-10 процессов по CPU"
