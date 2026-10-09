# Архитектура развертывания VPS

**Версия:** 1.3
**Дата:** 2026-10-09
**Статус:** УТВЕРЖДЕНО

> **Изменения в 1.2 (сверка с фактом, живой снимок хоста от 2026-10-08):**
> Источники версии 1.2 — реальный снимок прода, а не ручная ревизия: `docker ps` на хосте плюс чтение `config.yaml` внутри контейнеров `hermes-gateway` и `hermes-sysadmin` (`docker exec <ctr> cat /opt/data/config.yaml`).
> - **Контейнеры:** состав актуального `docker ps` (10 running) совпадает с 1.1; изменился только образ `dsh` — теперь отображается как image-id `53647345d871` без `repo:tag`.
> - **MCP-серверы:** добавлен новый раздел (gateway `mcp_servers`, стр. 540–565) — в 1.1 его не было.
> - **Ограничения прав агентов:** добавлен раздел с `disabled_toolsets` и `approvals.mode` (в 1.1 был только общий блок «Ограничения»).
> - **GitOps-пайплайн:** добавлен раздел, статус — **ПРОВЕРЕНО** (было «не проверено»).
> - Зафиксировано расхождение: gateway `mcp_servers.dsh-carrot.url = http://dsh:8090/mcp`, тогда как фактический порт контейнера `dsh` — 3080.

> **Изменения в 1.1 (сверка с фактом, снимок Docker от 2026-10-05):**
> - добавлены все 9 сетей с фактическими драйверами (mcp-network и hermes-net — bridge/local, а не external);
> - описаны сети по контейнерам: vpn-net, proxy-network, reverse-proxy_default, mail-relay_default;
> - уточнены published-порты: design-site-nginx:80 — не опубликован; mail-relay:465/tcp — не опубликован;
> - добавлен loopback-bind (127.0.0.1) у hermes-gateway, hermes-sysadmin, dsh, searxng, open-websearch;
> - добавлен контейнер weavescope (weaveworks/scope:1.13.2, Exited (255), ~4 мес) — лишний, кандидат на удаление;
> - устранено внутреннее противоречие по порту DSH: фактический порт — 3080 (ранее в разделе «Связи» ошибочно 8090).

## Контейнеры

Снимок `docker ps` от 2026-10-08 (10 running):

| Контейнер | Образ | Порты (host→container) | Bind | Статус | Назначение |
|-----------|-------|------------------------|------|--------|-----------|
| hermes-gateway | nousresearch/hermes-agent:v2026.9.24 | 8642→8642, 9119→9119 | 127.0.0.1 | Up (пересоздан 2026-10-08 после deploy) | Оркестратор, Telegram-бот |
| hermes-sysadmin | nousresearch/hermes-agent:v2026.9.24 | 8643→8642, 9120→9119 | 127.0.0.1 | Up 27h | Агент-администратор |
| dsh | `53647345d871` (repo:tag отсутствует) | 3080→3080 | 127.0.0.1 | Up 31h | DeepSeek Harness, MCP-мост |
| nginx-proxy | nginx:1.27-alpine | 80→80, 443→443 | 0.0.0.0 | Up 13d | Обратный прокси |
| design-site-nginx | nginx:alpine | 80/tcp объявлен, **НЕ опубликован** | — | Up 13d | Информационный сайт |
| mail-relay | ghcr.io/jchonig/postfix:latest | 25→25 (опубликован); 465/tcp объявлен, **НЕ опубликован** | 0.0.0.0 | Up 13d | Почтовый релей |
| 3x-ui | ghcr.io/mhsanaei/3x-ui:latest | 2053→2053, 8446→8446, 17431→17431 | 0.0.0.0 | Up 13d | VPN/прокси |
| searxng | searxng/searxng:latest | 8888→8080 | 127.0.0.1 | Up 13d | Поисковый движок |
| open-websearch | ghcr.io/aas-ee/open-web-search:latest | 3000→3000 | 127.0.0.1 | Up 13d | Веб-поиск |
| searxng-redis | redis:alpine | — | — | Up 13d | Кэш для searxng |
| docker-socket-proxy | tecnativa/docker-socket-proxy@sha256:1f5038b54f06c3e18422902cf00ba21803d1c97805aae032e5e6673d532d3459 | 2375 (internal) | — | — | Прокси Docker API с read-only allowlist |

> Контейнер **weavescope** из 1.1 в выводе `docker ps` (без `-a`) не виден — он либо остаётся `Exited`, либо удалён; отдельная проверка через `docker ps -a` в 1.2 не выполнялась.
> Изменение образа `dsh`: было `stefankhor/dsh-docker:latest`, стало голый image-id `53647345d871` — контейнер поднят из образа без repo:tag; кандидат на пересборку/ретег.

## Сети

> Раздел перенесён из 1.1 без изменений; в 1.2 сети повторно не перепроверялись.

Все сети имеют `scope=local`. Драйверы указаны фактически:

- **mcp-network** (bridge, local) — hermes-gateway, hermes-sysadmin, dsh, searxng, open-websearch, searxng-redis
- **hermes-net** (bridge, local) — hermes-sysadmin
- **vpn-net** (bridge, local) — nginx-proxy, 3x-ui, design-site-nginx
- **proxy-network** (bridge, local) — design-site-nginx
- **reverse-proxy_default** (bridge, local) — design-site-nginx
- **mail-relay_default** (bridge, local) — mail-relay
- **bridge** (bridge, local) — пусто
- **host** (host, local) — без IP, служебная
- **none** (null, local) — служебная

> Примечание: ранее mcp-network и hermes-net помечались как `external`; фактически это локальные bridge-сети.

## Связи

- hermes-gateway → A2A → hermes-sysadmin (порт 9900; внутри сети, наружу не публикуется)
- hermes-sysadmin → MCP → dsh (порт **3080**)
- dsh → docker-socket-proxy (DOCKER_HOST=tcp://docker-socket-proxy:2375)
- docker-socket-proxy → /var/run/docker.sock (read-only)
- dsh больше не имеет прямого доступа к docker.sock
- nginx-proxy → 80/443 наружу; проксирует design-site-nginx
- design-site-nginx доступен только из сетей vpn-net / proxy-network / reverse-proxy_default (порт наружу не опубликован)
- gateway → filesystem-plus MCP (ограничен /opt/data/workspace, не видит SOUL.md, config.yaml, .env, state.db)

> **Расхождение (обнаружено в 1.2):** в `mcp_servers` gateway сервер `dsh-carrot` настроен на `http://dsh:8090/mcp`, тогда как фактический порт контейнера `dsh` — **3080** (см. разделы «Контейнеры» и «MCP-серверы»). Требуется подтверждение: внутренний порт или устаревший endpoint.

## Роли агентов

- **hermes-gateway** — оркестратор, принимает задачи из Telegram, делегирует их
- **hermes-sysadmin** — администратор, выполняет задачи через DSH
- **dsh** — «руки», предоставляет Docker-инструменты с approval-гейтами

## MCP-серверы (gateway)

Источник: `hermes-gateway:/opt/data/config.yaml`, секция `mcp_servers` (стр. 540–565), снимок 2026-10-08.

| Сервер | Транспорт | Команда / URL | Примечание |
|--------|-----------|---------------|-----------|
| filesystem-plus | stdio (npx) | `npx -y @modelcontextprotocol/server-filesystem /opt/data/workspace` | доступ к рабочей папке |
| searxng-search | stdio (npx) | `npx -y @kassol/mcp-searxng`, env `SEARXNG_URL=http://searxng:8080` | поиск через searxng |
| vkusvill | streamable-http | `https://mcp.vkusvill.ru/mcp` | внешний MCP |
| dsh-carrot | streamable-http | `http://dsh:8090/mcp` (timeout 1200) | мост к DSH; **порт 8090 ≠ 3080 — см. «Связи»** |

## Ограничения прав агентов

Источник: `config.yaml` внутри контейнеров (снимок 2026-10-08).

| Агент | `disabled_toolsets` | `approvals.mode` |
|-------|---------------------|------------------|
| hermes-gateway | `[]` (ничего не отключено) | `manual` (enabled, require_approval) |
| hermes-sysadmin | `[terminal, code_execution]` | `manual` (enabled, require_approval) |

Базовые ограничения (перенесено из 1.1):

- hermes-sysadmin НЕ имеет доступа к Docker-сокету напрямую
- hermes-sysadmin НЕ имеет Telegram-токена
- Docker-инструменты доступны только через DSH
- Деструктивные операции требуют подтверждения
- dsh может docker_ps/docker_logs/docker_inspect; dsh НЕ может restart/stop/rm/exec (POST=0, EXEC=0 в прокси, при попытке — 403 от haproxy)
- gateway: MCP filesystem-plus имеет доступ только к /opt/data/workspace

## GitOps-пайплайн

**Статус: ПРОВЕРЕНО** (было «не проверено»).

Пайплайн: изменение в репозитории `sergeiivanovmore-ai/infra-gitops` → merge в `main` → GitHub Actions workflow `deploy.yml` → `scripts/deploy-infra.sh` (под root) → `cp` файла в bind-mount (`/opt/docker/hermes/data`) → `docker compose up -d --force-recreate`.

Подтверждение от 2026-10-08: PR #9 → merge `18:52:20` → срабатывание Actions `deploy.yml` → `deploy-infra.sh` → пересоздание `hermes-gateway` (uptime ~9 мин на момент снимка). Деплой применяется к живым контейнерам за ~13 с после merge.
