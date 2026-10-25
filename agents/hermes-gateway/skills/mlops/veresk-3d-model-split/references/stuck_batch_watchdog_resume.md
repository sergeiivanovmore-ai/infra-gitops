# Застрявший батч: сторож, возобновление, «цикл отчётов»

Кейс Дарио: батч из 211 предметов умер на №89, 88 готовы. Сторож каждые
3 минуты слал одно и то же 13 часов. Пользователь пришёл с «работа зависла»,
«отчёт без изменений», «процесс зашёл в цикл».

## 🚨 «Процесс зашёл в цикл» — почти всегда сторож без дедупликации

Пользователь описывает цикл **своими глазами**: одинаковые сообщения в чате.
Проверять в первую очередь, а не процессы:

```bash
# что реально запущено
ps aux --sort=-%cpu | head -15
uptime; free -m

# что рассылает отчёты
cronjob(action='list')          # смотри schedule/repeat/last_status
```

Пустой `ps` + нулевой load + чистый `Blender quit` в логе = **процессы не
работают, «цикл» — это cron-отчёты**.

## Сторож v1: почему он спамил

```python
if dead and not finished:
    print("⚠️ Процесс завершился, а работа не закончена (%d/%d)" % (done, total))
```

Алерт печатался при **каждом** запуске. Состояние «мертво» длится часами →
13 часов одинаковых сообщений.

Признак, что сторож виноват, а не процесс: алерт **точно соответствует
правде**. Сторож был прав — он сообщал о застрявшем батче. Спамил он
не потому, что врал, а потому, что не помнил, что уже сообщал.

## Сторож v2: дедупликация по смене состояния

Рабочий сторож: `/opt/data/scripts/dario_watchdog2.py`.

```python
if done != state.get("last_done"):
    last_change = now          # прогресс двигает «последнее изменение»
idle = now - last_change

if finished:                                   sig = "done"
elif crashed:                                  sig = "crash"
elif live == 0 and done < TOTAL:                sig = "dead"
elif idle > STALL_SEC:                          sig = "stall"
else:                                           sig = "working"

prev_sig = state.get("sig")
last_alert_sig, last_alert_ts = state.get("last_alert_sig"), state.get("last_alert_ts", 0)

if sig in ("dead", "crash", "stall"):
    repeat = (sig == prev_sig)
    if not repeat or (now - last_alert_ts) > SAME_ALERT_GAP:   # 4 часа
        msg = "..."
elif sig == "working":
    if (now - last_report_ts) > REPORT_EVERY:                 # 1 час
        msg = "ℹ️ ..."
elif sig == "done" and not state.get("finished_reported"):
    msg = "✅ ..."          # завершение — ровно один раз
```

Правила:
- **состояние** = один из `done/crash/dead/stall/working`, а не сырое условие;
- то же событие — не чаще раза в 4 часа (`SAME_ALERT_GAP`);
- прогресс — не чаще раза в час (`REPORT_EVERY`);
- завершение — один раз (`finished_reported`);
- **пустой stdout = тишина** (для `no_agent=True`).

Проверка перед установкой:

```bash
python3 /opt/data/scripts/dario_watchdog2.py   # 1-й: сообщил
python3 /opt/data/scripts/dario_watchdog2.py   # 2-й: пусто
python3 /opt/data/scripts/dario_watchdog2.py   # 3-й: пусто
```

Второй и третий прогон обязаны быть пустыми. Если нет — дедупликация не работает.

## 🚨 Не запускай скрипт, который начинается с `rm -rf`

```bash
head -20 /tmp/vil/run_batch_dario.sh
# rm -rf "$D/parts" "$D/renders"      ← стёр бы все 88 готовых файлов!
```

**Всегда смотри первые строки скрипта перезапуска.** Прогоны батча пишут
в фиксированные `parts/` и `renders/`, и скрипт их чистит «для чистоты».

## Возобновление вместо перезапуска

`batch_split_render.py` умеет `resume` — пропускает непустые готовые файлы:

```bash
blender --background --factory-startup --python scripts/batch_split_render.py -- \
  '{"fbx":"<модель>", "index":"<items_index.json>",
    "parts_dir":"<D>/parts", "renders_dir":"<D>/renders",
    "report":"<D>/split_report.json",
    "resume":true, "res":1024, "samples":64}'
```

Проверяемый вывод на старте:

```
ITEMS=211
ITEM 1/211 n=1 objects=8 SKIP (уже готов)
...
ITEM 89/211 n=89 objects=176 X 159.74-163.27 ... -> 89_iso.png
```

`resume` по умолчанию **выключен** (`C.get("resume", False)`) — без него
всё пересчитается заново.

Быстрая проверка одного предмета перед возобновлением всего батча:

```bash
blender --background --python scripts/batch_split_render.py -- \
  '{"fbx":"...","index":"...","parts_dir":"/tmp/t89","renders_dir":"/tmp/t89r",
    "report":"/tmp/t89.json","only":[89],"res":1024,"samples":64}'
```

59 секунд вместо бесконечности — и сразу видно, что фикс работает.

## Порядок при застрявшем батче

1. `ps` / `uptime` — работает ли что-нибудь вообще
2. `cronjob list` — кто рассылает отчёты; снять паузу, если спам
3. `tail` лога батча — на каком `ITEM` встал
4. **не** перезапускать скрипт вслепую — сначала `head -20` на `rm -rf`
5. локализовать причину на одном предмете (`only`)
6. починить, проверить на одном предмете, **потом** `resume: true`
7. новый сторож с дедупликацией; `only-slices` для глазомерной проверки кадров
8. `cronjob action='run'` + `action='list'` — убедиться, что `last_status: ok`

## Отчёт пользователю — сразу, а не по запросу

Пользователь жаловался несколько часов. Стоимость проактивного сообщения
(одна строка статуса) несопоставима с ценой его ожидания. Формат:

```
Готово:     4 части загружены в 3dmodels/Penaly/{models,renders}, md5 сошёлся.
Не сделано: осталось 121 предмет, идёт.
Ждём вас:   ничего — отпишусь при изменении.
```

Признак, что отчёт не дошёл: пользователь пишет «отчёт без изменений».
Значит он смотрит **на Drive** и там пусто — то есть прогон остановлен до
загрузки, а не «медленный». Проверяй последний выполненный шаг, а не скорость.