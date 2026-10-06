# Архитектура развертывания VPS

**Версия:** 1.1
**Дата:** 2026-10-05
**Статус:** УТВЕРЖДЕНО

> **Изменения в 1.1 (сверка с фактом, снимок Docker от 2026-10-05):**
> - добавлены все 9 сетей с фактическими драйверами (mcp-network и hermes-net — bridge/local, а не external);
> - описаны сети по контейнерам: vpn-net, proxy-network, reverse-proxy_default, mail-relay_default;
> - уточнены published-порты: design-site-nginx:80 — не опубликован; mail-relay:465/tcp — не опубликован;
> - добавлен loopback-bind (127.0.0.1) у hermes-gateway, hermes-sysadmin, dsh, searxng, open-websearch;
> - добавлен контейнер weavescope (weaveworks/scope:1.13.2, Exited (255), ~4 мес) — лишний, кандидат на удаление;
> - устранено внутреннее противоречие по порту DSH: фактический порт — 3080 (ранее в разделе «Связи» ошибочно 8090).

## Контейнеры

| Контейнер | Образ | Порты (host→container) | Bind | Статус | Назначение |
|-----------|-------|------------------------|------|--------|-----------|
| hermes-gateway | nousresearch/hermes-agent:v2026.9.24 | 8642→8642, 9119→9119 | 127.0.0.1 | Up | Оркестратор, Telegram-бот |
| hermes-sysadmin | nousresearch/hermes-agent:v2026.9.24 | 8643→8642, 9120→9119 | 127.0.0.1 | Up | Агент-администратор |
| dsh | stefankhor/dsh-docker:latest | 3080→3080 | 127.0.0.1 | Up | DeepSeek Harness, MCP-мост |
| nginx-proxy | nginx:1.27-alpine | 80→80, 443→443 | 0.0.0.0 | Up | Обратный прокси |
| design-site-nginx | nginx:alpine | 80/tcp объявлен, **НЕ опубликован** | — | Up | Информационный сайт |
| mail-relay | ghcr.io/jchonig/postfix:latest | 25→25 (опубликован); 465/tcp объявлен, **НЕ опубликован** | 0.0.0.0 | Up | Почтовый релей |
| 3x-ui | ghcr.io/mhsanaei/3x-ui:latest | 2053→2053, 8446→8446, 17431→17431 | 0.0.0.0 | Up | VPN/прокси |
| searxng | searxng/searxng:latest | 8888→8080 | 127.0.0.1 | Up | Поисковый движок |
| open-websearch | ghcr.io/aas-ee/open-web-search:latest | 3000→3000 | 127.0.0.1 | Up | Веб-поиск |
| searxng-redis | redis:alpine | — | — | Up | Кэш для searxng |
| **weavescope** | weaveworks/scope:1.13.2 | — | — | **Exited (255), ~4 мес** | Лишний контейнер, кандидат на удаление |

## Сети

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
- hermes-sysadmin → MCP → dsh (порт 3080)
- dsh → Docker socket → управление контейнерами хоста
- nginx-proxy → 80/443 наружу; проксирует design-site-nginx
- design-site-nginx доступен только из сетей vpn-net / proxy-network / reverse-proxy_default (порт наружу не опубликован)

## Роли агентов

- **hermes-gateway** — оркестратор, принимает задачи из Telegram, делегирует их
- **hermes-sysadmin** — администратор, выполняет задачи через DSH
- **dsh** — «руки», предоставляет Docker-инструменты с approval-гейтами

## Ограничения

- hermes-sysadmin НЕ имеет доступа к Docker-сокету напрямую
- hermes-sysadmin НЕ имеет Telegram-токена
- Docker-инструменты доступны только через DSH
- Деструктивные операции требуют подтверждения
