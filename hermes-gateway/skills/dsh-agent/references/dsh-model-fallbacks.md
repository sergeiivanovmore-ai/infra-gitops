# DSH: выбор модели и сигнатуры сбоев

Проверено в сентябре 2026. Заменяет прежний вывод «agent_run/task_inbox сломаны,
работай локально» из `dsh-timeout-issue-2025-09.md` — тот вывод был неверен.

## Корневая причина «зависаний» DSH

`agent_run` и `task_inbox` **работают**. Таймауты 600с и очередь, застрявшая в
`queued`, вызваны **перегруженной моделью по умолчанию**, а не поломкой DSH:

- Дефолт: `provider=openrouter`, `model=nvidia/nemotron-3-ultra-550b-a55b:free`
- Эта модель отдаёт `Upstream error from Nvidia: Service temporarily overloaded`,
  а затем вызовы виснут до `TimeoutError: MCP call timed out after 600.0s`.
- Однажды запущенная на ней сессия «залипает»: дальнейшие вызовы в тот же cwd
  тоже виснут.

## Проверенный fix

Задавай модель явно в `agent_run` / `task_inbox`:

```
provider="openrouter", model="deepseek/deepseek-v4-flash"
```

Этого достаточно в подавляющем большинстве случаев — bash, создание и чтение
файлов, веб выполняются за секунды.

## Сигнатуры ошибок (что означает что)

| Текст | Значение | Действие |
|-------|----------|----------|
| `PI_AI_ERROR: Upstream error from Nvidia: Service temporarily overloaded` | перегружен дефолтный nvidia | сменить модель |
| `MCP call timed out after 600.0s` | висящая сессия на мёртвой модели | сменить модель / cwd / sessionId |
| `MISSING_CREDENTIAL: llm-deepseek: no API key for provider route "deepseek-official"` | провайдер без ключа | использовать `openrouter` + `deepseek/deepseek-v4-flash` |
| `MCP server 'dsh-carrot' is unreachable after N consecutive failures` | MCP-мост временно мёртв | подождать ~60с авто-retry, не долбить вызовами |
| задача в `task_inbox` висит в `queued` | воркер занят зависшей сессией | `task_cancel(taskId)` → синхронный `agent_run` с рабочей моделью |

## Доступные маршруты моделей (из `model_list`)

Routable providers: `deepseek-official` (ключ НЕ настроен), `openrouter`.

Надёжные для задач с tool-calling (через `openrouter`):
- `deepseek/deepseek-v4-flash` — проверенный fallback ✅
- `z-ai/glm-5-turbo`, `qwen/qwen3.6-plus`, `minimax/minimax-m2.7`
- лёгкие/дешёвые: `inclusionai/ling-2.6-flash`, `stepfun/step-3.5-flash:free`,
  `xiaomi/mimo-v2-flash:free`

Избегать как основной: `nvidia/nemotron-3-ultra-550b-a55b:free` (дефолт, перегружен).

## Проверочный паттерн (create + verify)

Запись файла в DSH-песочнице **нельзя проверить из Hermes** — её файловый
namespace изолирован (`/home/dsh` и `/opt/dsh` в Hermes не видны). Поэтому:

1. `agent_run` создаёт файл.
2. Второй `agent_run` **в той же сессии** (`sessionId`) просит `ls -la`, `md5sum`, `cat`.
   Сверь: длина содержимого + перевод строки (напр. `"landlock works\n"` = 15 байт
   практически подтверждает, что запись реальная, а не галлюцинация).
