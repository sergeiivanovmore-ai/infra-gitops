# Инфра-отчёт
Снят: 2026-10-29T05:36:01+00:00
Хост: 202371.com | ядро: 6.8.0-138-generic

## Контейнеры: статус, рестарты, здоровье
design-site-nginx | running | restarts=0 | health=- | 2026-10-17T12:40:07
docker-socket-proxy | running | restarts=0 | health=- | 2026-10-28T06:32:06
dsh | running | restarts=0 | health=- | 2026-10-27T20:29:14
hermes-gateway | running | restarts=0 | health=- | 2026-10-27T17:54:54
hermes-orchestrator | running | restarts=0 | health=- | 2026-10-28T22:30:12
hermes-sysadmin | running | restarts=0 | health=- | 2026-10-28T22:43:05
hermes-work | running | restarts=0 | health=- | 2026-10-25T14:46:38
jt-site-prod | running | restarts=0 | health=healthy | 2026-10-17T12:40:07
jt-site-staging | running | restarts=0 | health=- | 2026-10-17T12:40:07
mail-relay | running | restarts=0 | health=- | 2026-10-17T12:40:07
nginx-proxy | running | restarts=0 | health=healthy | 2026-10-23T11:22:30
open-websearch | running | restarts=0 | health=- | 2026-10-17T12:40:07
searxng | running | restarts=0 | health=- | 2026-10-17T12:40:07
searxng-redis | running | restarts=0 | health=- | 2026-10-17T12:40:07

## Сети контейнеров (ручные подключения теряются при пересоздании)
design-site-nginx: proxy-network reverse-proxy_default vpn-net 
docker-socket-proxy: mcp-network 
dsh: mcp-network 
hermes-gateway: mcp-network 
hermes-orchestrator: hermes-net mcp-network 
hermes-sysadmin: hermes-net mcp-network 
hermes-work: hermes-net mcp-network 
jt-site-prod: hermes-net vpn-net 
jt-site-staging: hermes-net vpn-net 
mail-relay: mail-relay_default 
nginx-proxy: hermes-net vpn-net 
open-websearch: mcp-network 
searxng: mcp-network 
searxng-redis: mcp-network 

## Ресурсы
/dev/vda1        59G   37G   20G  66% /
MemTotal:        8132192 kB
MemAvailable:    5140656 kB
loadavg: 0.29 0.16 0.11 1/829 2869307

## nginx: проверка конфига
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful

## Домены
jt-design.ru=200
stg.jt-design.ru=200
sysadmin.jt-design.ru=302
analists.jt-design.ru=502
orchestrator.jt-design.ru=302

## Сертификаты: срок действия
analists.jt-design.ru | Jan 10 18:05:12 2027 GMT | дней: 73
jt-design.ru | Dec 24 14:31:20 2026 GMT | дней: 56
orchestrator.jt-design.ru | Jan 10 17:55:28 2027 GMT | дней: 73
stg.jt-design.ru | Jan 13 07:19:26 2027 GMT | дней: 76
sysadmin.jt-design.ru | Jan 20 10:18:15 2027 GMT | дней: 83

## Почта: очередь Postfix
Mail queue is empty

## Последний прогон деплоя (хвост)
[owners] нет /opt/docker/dsh/data/settings.yaml -- пропуск
[owners] готово
  owners: права на конфиги в порядке (попытка 1)
  публикатор: завершился с ошибкой (деплой не затронут)

## Диск: крупнейшие каталоги /opt/docker (глубина 2)
681M	/opt/docker/dsh/workspace/.pw-browsers
1001M	/opt/docker/hermes-orchestrator/data/cache
1.1G	/opt/docker/hermes-work/
1.1G	/opt/docker/hermes-work/data
1.2G	/opt/docker/dsh/
1.2G	/opt/docker/dsh/workspace
1.3G	/opt/docker/hermes/data/workspace
1.9G	/opt/docker/hermes-orchestrator/data/installs
2.1G	/opt/docker/hermes/
2.1G	/opt/docker/hermes/data
4.3G	/opt/docker/hermes-orchestrator/
4.3G	/opt/docker/hermes-orchestrator/data

## Диск: крупнейшие файлы больше 100 МБ
123912 KB	/opt/docker/hermes-orchestrator/data/home/.local/lib/python3.14/site-packages/playwright/driver/node
142236 KB	/opt/docker/hermes-orchestrator/data/installs/351f81cc06284494/environments/c762e4d4c7954d8a99258845ed6219c8/workspace/tools/ffmpeg-9.0.1-linux-x64/bin/ffprobe
142440 KB	/opt/docker/hermes-orchestrator/data/installs/351f81cc06284494/environments/c762e4d4c7954d8a99258845ed6219c8/workspace/tools/ffmpeg-9.0.1-linux-x64/bin/ffmpeg
144320 KB	/opt/docker/hermes-orchestrator/data/installs/351f81cc06284494/environments/c762e4d4c7954d8a99258845ed6219c8/workspace/tools/ffmpeg-9.0.1-linux-x64/bin/ffplay
144412 KB	/opt/docker/hermes-orchestrator/data/installs/351f81cc06284494/environments/c762e4d4c7954d8a99258845ed6219c8/workspace/tools/node-26.7.0-linux-x64/bin/node
187024 KB	/opt/docker/hermes-sysadmin/data/state.db
202616 KB	/opt/docker/dsh/workspace/.pw-browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell
202616 KB	/opt/docker/hermes-orchestrator/data/cache/pw-browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell
242588 KB	/opt/docker/hermes-orchestrator/data/installs/351f81cc06284494/environments/c762e4d4c7954d8a99258845ed6219c8/workspace/tools/python-3.14.7+20260901-linux-x64/lib/libpython3.14.so.1.0
263460 KB	/opt/docker/hermes-orchestrator/data/installs/351f81cc06284494/environments/c762e4d4c7954d8a99258845ed6219c8/workspace/tools/chromium-1208/chrome-linux64/chrome
294132 KB	/opt/docker/dsh/workspace/.pw-browsers/chromium-1248/chrome-linux64/chrome
294132 KB	/opt/docker/hermes-orchestrator/data/cache/pw-browsers/chromium-1248/chrome-linux64/chrome

## ТРЕВОГИ
- домен analists.jt-design.ru отвечает 502
