---
name: deploy-service
description: "Развёртывание нового сервиса на VPS через GitOps: ARCHITECTURE.md → разведка → артефакты → PR через DSH → certbot → TLS → обновление ARCHITECTURE.md"
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [gitops, deploy, docker, nginx, reverse-proxy, certbot, dsh, a2a, vps, architecture]
    related_skills: [a2a-peer-agents, dsh-agent]
---

# Развёртывание сервиса на VPS через GitOps

Проверенный путь: «хочу новый сервис на домене» → работающий HTTPS, без ручных правок на хосте. Всё, что можно версионировать, идёт через PR; руками остаётся ровно один шаг — выпуск сертификата.

Главный принцип: hermes-sysadmin/ARCHITECTURE.md — единственный источник истины по топологии VPS. Читается первым, обновляется последним в том же PR. Без этого изменение не считается завершённым.

## Когда использовать

- Новый docker-сервис на том же VPS, где уже живут nginx-proxy, hermes-gateway, dsh.
- Нужен внешний доступ по домену service.<domain> при запрете публиковать порт наружу.
- Репозиторий-эталон: sergeiivanovmore-ai/infra-gitops (ветка main), пайплайн merge в main → GitHub Actions deploy.yml → scripts/deploy-infra.sh (под root на хосте).

## Роли и каналы

| Кто | Что делает | Канал |
|-----|-----------|-------|
| Пользователь | мерж PR, выпуск сертификата, хостовые операции | GitHub UI, терминал хоста |
| Оркестратор (Hermes) | дробит задачу, передаёт пиру, проверяет результат, отчитывается | a2a_call(agent="sysadmin") |
| Пир sysadmin | разведка стека, генерация артефактов, постановка задач | свой контекст + DSH |
| DSH | фактическая работа с репо и docker | mcp__dsh__task_inbox(cwd="/home/dsh/workspace") |

У пира нет прямых `mcp__github__*`. Единственный путь к репозиторию — одна пошаговая задача в mcp__dsh__task_inbox, результат забирать mcp__dsh__task_result. GitHub MCP подключён внутри DSH.

## Железные правила

1. ARCHITECTURE.md — первое и последнее. Прочитать до проектирования (Фаза −1). Обновить в том же PR (Фаза 2). Без этого изменение не считается завершённым.
2. Ничего не коммитить/пушить/мержить самому. PR создаёт DSH, мержит — пользователь.
3. Порт наружу не публиковать. Только 127.0.0.1:<port>:<port> + reverse-proxy по docker-сети.
4. Один шаг — одно подтверждение. После каждого шага остановиться и ждать «ок».
5. Self-report пира — не доказательство. Требовать URL PR, head.sha, diff --stat, размеры/md5 и подтверждать read-only запросом.
6. Артефакты до PR. Сначала тексты (compose, nginx, diff, doc), потом создание PR.

## Workflow по фазам

### Фаза −1 — чтение ARCHITECTURE.md (обязательно, всегда первым)

Ни одно проектное решение не принимается до прочтения `hermes-sysadmin/ARCHITECTURE.md` из `main`.

Это единственный источник истины по топологии VPS. Читается через mcp__github__get_file_contents (через DSH task_inbox, если у пира нет прямого доступа). Содержит:

- актуальную версию, дату, историю изменений;
- полный состав контейнеров (образ, порты, bind, uid, сети);
- все docker-сети и их участников;
- связи между сервисами (кто к кому как ходит);
- ограничения прав агентов;
- паттерны, которые уже приняты (dual-home, loopback-bind, edge-DMZ, структура deploy-infra.sh);
- GitOps-пайплайн.

Если предлагаемое изменение конфликтует с ARCHITECTURE.md — явно сообщить об этом до генерации артефактов. Либо отклонить идею, либо обосновать, почему документ нужно обновить.

Проверка: после чтения вернуть короткое подтверждение — версия, дата, ключевые факты из разделов «Сети», «Связи», «Контейнеры». Без этого не начинать проектирование.

### Фаза 0 — разведка (read-only, дополнительно к Фазе −1)

ARCHITECTURE.md описывает состояние на дату документа. Перед изменениями — сверить с живым хостом, потому что документация может отставать:

- какие контейнеры реально запущены (docker ps);
- какие сети реально существуют;
- какие bind-mount'ы у nginx-proxy и других ключевых сервисов;
- какое содержимое у conf.d reverse-proxy;
- какой uid у образа нового сервиса (docker run --rm <image> id).

Расхождения между ARCHITECTURE.md и фактическим хостом — зафиксировать и решить, что обновлять в документе.

### Фаза 1 — анализ

Ответить письменно (до артефактов):

1. В какую существующую сеть ставить сервис и почему.
2. Как он ходит к внутренним API (по docker-сети или через host loopback).
3. Нужен ли доступ к dsh / nginx / другим сервисам.
4. Какие разделы ARCHITECTURE.md затрагиваются.
5. Какие ограничения из ARCHITECTURE.md влияют.

Отдельно проверить: видит ли edge-прокси (nginx-proxy) сервис в его сети. Если nginx-proxy в vpn-net, а сервис планируется в mcp-network — понадобится dual-home (см. грабли «dual-home»).

### Фаза 2 — артефакты

Собрать тексты, ничего не создавая:

- docker/docker-compose.<service>.yml (шаблон: references/service-compose.template.yml);
- reverse-proxy/conf.d/<service>.conf — сначала HTTP-only для ACME (references/reverse-proxy-http.conf), TLS — отдельным PR (references/reverse-proxy-tls.conf);
- unified diff для scripts/deploy-infra.sh (шаблон блока: references/deploy-infra-block.template.sh).

Diff для `hermes-sysadmin/ARCHITECTURE.md` — обязательная часть того же PR. Не отдельный PR, не «потом». Обновляется:

1. Шапка. Версия 1.N → 1.N+1, дата — сегодня.
2. Блок изменений. В начале документа добавляется > **Изменения в 1.N+1 (дата):** со списком: что добавлено (контейнер/сервис, образ, порт, сети); что изменено в scripts/deploy-infra.sh; какие конфиги nginx добавлены/изменены; данные, пути, uid.
3. Раздел «Контейнеры». Новая строка в таблице с полными полями: имя, образ, порты host→container, bind, статус, назначение. Плюс обновление счётчика «N running» в заголовке.
4. Раздел «Сети». Добавить сервис в списки всех сетей, в которых он участвует (mcp-network и/или vpn-net).
5. Раздел «Связи». Новые рёбра: <edge-proxy> → <svc>:<port> (через сеть), <svc> → <inner-api>:<port> (через сеть).
6. Раздел «GitOps-пайплайн». Если менялся порядок или добавлялся блок — обновить описание.
7. Открытые вопросы. Если остались (домен ещё не выбран, конфиг вне репо и т.п.) — добавить отдельным блоком.

Если по итогам работы ARCHITECTURE.md не обновлён — PR неполный. Устаревшая архитектура = следующее развёртывание пойдёт по неправильному рецепту.

### Фаза 3 — PR

Одна задача для DSH: get_file_contents (main) → create_branch → push_files → create_pull_request с телом PR. Порядок PR при внешнем домене:

1. adopt существующих конфигов прокси в GitOps (без изменений содержимого);
2. сервис + HTTP-only conf;
3. *вручную* — certbot;
4. TLS conf + снятие пометок «HTTP-only» в документации.

### Фаза 4 — мерж (пользователь)

Напомнить, что мержит он сам; после мержа Actions прогонит deploy-infra.sh.

### Фаза 5 — проверка инфраструктуры

docker ps/inspect/port, сети, mount'ы, ответ на loopback, nginx -t, наличие conf, логи без error, связь с внутренним API. Таблица «проверка → ожидание → факт → OK/FAIL».

### Фаза 6 — TLS

Сертификат выпускается после того, как nginx отвечает на /.well-known/acme-challenge/:

    sudo certbot certonly --webroot -w /var/www/certbot \
      -d <domain> --cert-name <domain> --key-type ecdsa --agree-tos --no-eff-email

Если хостовый certbot падает (см. грабли) — запускать через docker-образ:

    docker run --rm \
      -v /etc/letsencrypt:/etc/letsencrypt \
      -v /var/lib/letsencrypt:/var/lib/letsencrypt \
      -v /var/www/certbot:/var/www/certbot \
      certbot/certbot certonly \
        --webroot -w /var/www/certbot \
        -d <domain> --cert-name <domain> \
        --key-type ecdsa --agree-tos --no-eff-email --non-interactive

Только после успешного выпуска — PR с TLS-блоком.

## Грабли (симптом → причина → правило)

### 1. Хостовые пути /opt/docker недоступны из контейнеров

*Симптом:* чтение /opt/docker/... через dsh/agent_run даёт 403, cwd not allowed, либо роняет MCP в anti-loop.

*Причина:* docker-socket-proxy read-only (EXEC=0), workspaceRoots ограничивает cwd, хостового shell у агентов нет.

*Правило:* конфиги хоста из контейнера не читать. Просить у пользователя содержимое (base64/текст) либо adopt через docker cp из живого контейнера. cwd всегда /home/dsh/workspace.

### 2. Trailing newline теряется при create_or_update_file

*Симптом:* файл в репо на 1 байт меньше присланного, md5 не сходится.

*Причина:* GitHub отбрасывает завершающий \n при загрузке контента.

*Правило:* для nginx-конфигов это безвредно — не гнаться за байт-точностью. Если точность критична (adopt «как есть»), добавлять перевод строки отдельным коммитом и сверять md5.

### 3. Порядок блоков в deploy-infra.sh (важно!)

*Подтверждено в сессии:* деплой дважды падал:

    nginx: [emerg] host not found in upstream "hermes-studio" in studio.conf:12
    cp: cannot create regular file '.../docker-compose.yml': No such file or directory

*Причина:*
1. nginx reload стоял сразу после копирования conf.d — до того, как контейнер нового сервиса запущен и зарегистрирован в сети. nginx не может зарезолвить upstream.
2. mkdir -p /opt/docker/<svc>/data стоял после cp compose — сам каталог /opt/docker/<svc>/ ещё не существовал.

*Правило:*
1. mkdir -p /opt/docker/<svc>/data — до cp compose.
2. nginx reload — в самом конце, после всех docker compose up -d, с sleep 5 перед ним (docker DNS должен успеть зарегистрировать сервис).
3. nginx -t && nginx -s reload || echo "  WARN: ..." — валидация до перезагрузки, падение не роняет деплой (совместимо с set -euo pipefail).

### 4. Хостовый certbot сломан — выпускать через docker-образ

*Подтверждено в сессии:* хостовый certbot падал с

    AttributeError: module 'lib' has no attribute 'GEN_EMAIL'

Несовместимость системного pyOpenSSL (Ubuntu 22.04) с обновлённой cryptography. Выпуск через docker-образ certbot/certbot сработал сразу.

*Правило:* если хостовый certbot падает — запускать официальный образ с теми же bind-mount'ами webroot (-v /var/www/certbot:/var/www/certbot и /etc/letsencrypt), команда та же (certonly --webroot -w /var/www/certbot).

### 5. .env сервиса перебивает environment: в compose

*Подтверждено в сессии:* gateway уходил в retry-loop

    Refusing to bind dashboard to 0.0.0.0 — no auth providers

Из-за HERMES_DASHBOARD=1 в /opt/docker/hermes/data/.env. Hermes читает .env с override=True, перебивая compose env.

*Правило:* не верить глазам compose — сверять фактический env: docker inspect <c> --format '{{json .Config.Env}}' (docker exec env часто недоступен). Если значение приходит из .env — нормализовать его в deploy-infra.sh (sed по нужной строке), чтобы не возвращалось при пересоздании.

### 6. uid образа нужно проверять, а не угадывать

*Симптом:* слепой chown 1000:1000 на каталог данных → сервис не пишет файлы.

*Правило:* сначала docker run --rm <image> id. Если uid=0 — chown не нужен вовсе. Если uid неизвестен — в скрипте писать chown -R "${UID:-1000}:${GID:-1000}" и явно помечать значение как неподтверждённое.

### 7. У пира нет mcp__github__* — только DSH

*Правило:* не формулировать задачу как «используй github-тул». Формулировать один самодостаточный пошаговый план для mcp__dsh__task_inbox(cwd="/home/dsh/workspace").

### 8. Anti-loop в A2A

*Симптом:* Anti-loop protection: context ... exceeded 5 turns.

*Правило:* один контекст — максимум ~5 ходов. Новая крупная задача = новый контекст, и сообщение в нём должно быть самодостаточным (инлайнить артефакты, base64, тексты).

### 9. Таймаут A2A на длинных задачах

*Симптом:* [agent did not reply in time].

*Правило:* не повторять длинный вызов — это дублирует побочные эффекты. Сначала статус-пинг: «ответь одной строкой: ветка/PR/SHA, больше ничего не делай». Затем отдельная read-only проверка результата.

### 10. BRANCH_HEAD_SHA от DSH может быть неверным

*Симптом:* в отчёте SHA ветки совпадает с SHA main.

*Правило:* верить head.sha из pull_request_read, а не отдельному полю; расхождения выносить в отчёт.

### 11. Dual-home: сервис в двух сетях, если edge-прокси в другой сети

*Симптом:* nginx-proxy в vpn-net, сервис в mcp-network — прокси не резолвит сервис.

*Правило:* не тащить edge-прокси во внутренний сегмент (расширяет поверхность атаки). Подключать сервис к обеим сетям: mcp-network (внутренние API) + сеть edge — по прецеденту design-site-nginx.

### 12. Порт только на loopback

*Правило:* 127.0.0.1:<port>:<port>, наружу не публиковать ничего. Внешний вход — только через edge-прокси по docker-сети.

## Чек-лист перед созданием PR

- [ ] ARCHITECTURE.md прочитан в Фазе −1, решения опираются на него;
- [ ] расхождения ARCHITECTURE.md ↔ хост зафиксированы;
- [ ] в артефактах нет секретов (ключей, токенов, паролей);
- [ ] порт публикуется только на 127.0.0.1;
- [ ] uid образа проверен через docker run --rm <image> id;
- [ ] mkdir -p для data-каталога — до cp compose;
- [ ] в deploy-infra.sh блок сервиса врезан после reverse-proxy-блока;
- [ ] nginx reload — в самом конце скрипта (после всех docker compose up -d);
- [ ] nginx -t стоит до nginx -s reload, || echo WARN не роняет деплой;
- [ ] в diff'ах нет опечаток в именах (например seriivanovmore-ai вместо sergeiivanovmore-ai — пропущена g, ханк не применится байт-в-байт);
- [ ] ARCHITECTURE.md обновлён в этом же PR:
  - [ ] шапка: версия 1.N → 1.N+1, дата;
  - [ ] добавлен блок «Изменения в 1.N+1»;
  - [ ] таблица «Контейнеры» — новая строка + счётчик running;
  - [ ] раздел «Сети» — сервис добавлен во все его сети;
  - [ ] раздел «Связи» — новые рёбра;
  - [ ] раздел «GitOps-пайплайн» — если менялся;
  - [ ] «Открытые вопросы» — если остались.

## Шаблоны

- references/service-compose.template.yml — compose нового сервиса (loopback + dual-home).
- references/reverse-proxy-http.conf — HTTP-only фаза для ACME.
- references/reverse-proxy-tls.conf — TLS-фаза (после certbot).
- references/deploy-infra-block.template.sh — блок для scripts/deploy-infra.sh с правильным порядком.

## Смежные материалы

- a2a-peer-agents — делегирование пиру, статус-пинги, проверка побочных эффектов.
- dsh-agent — прямой доступ к DSH через MCP.
