# Инфра-отчёт
Снят: 2026-10-23T11:53:53+00:00
Хост: 202371.com | ядро: 6.8.0-138-generic

## Контейнеры: статус, рестарты, здоровье
design-site-nginx | running | restarts=0 | health=- | 2026-10-17T12:40:07
docker-socket-proxy | running | restarts=0 | health=- | 2026-10-17T12:40:07
dsh | running | restarts=0 | health=- | 2026-10-23T11:15:34
hermes-gateway | exited | restarts=0 | health=- | 2026-10-09T19:26:33
hermes-orchestrator | running | restarts=0 | health=- | 2026-10-17T12:40:07
hermes-studio | running | restarts=0 | health=- | 2026-10-23T09:46:11
hermes-sysadmin | running | restarts=0 | health=- | 2026-10-22T19:33:42
hermes-work | running | restarts=0 | health=- | 2026-10-17T12:55:29
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
hermes-orchestrator: hermes-net mcp-network 
hermes-studio: mcp-network vpn-net 
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
/dev/vda1        59G   48G  8.3G  86% /
MemTotal:        8132192 kB
MemAvailable:    3636028 kB
loadavg: 0.08 0.13 0.15 3/1003 1152020

## nginx: проверка конфига
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful

## Домены
jt-design.ru=200
stg.jt-design.ru=200
sysadmin.jt-design.ru=302
analists.jt-design.ru=302
orchestrator.jt-design.ru=302

## Сертификаты: срок действия
analists.jt-design.ru | Jan 10 18:05:12 2027 GMT | дней: 79
jt-design.ru | Dec 24 14:31:20 2026 GMT | дней: 62
orchestrator.jt-design.ru | Jan 10 17:55:28 2027 GMT | дней: 79
stg.jt-design.ru | Jan 13 07:19:26 2027 GMT | дней: 81
sysadmin.jt-design.ru | Jan 20 10:18:15 2027 GMT | дней: 88

## Почта: очередь Postfix
Mail queue is empty

## Последний прогон деплоя (хвост)
nginx: configuration file /etc/nginx/nginx.conf test is successful
2026/10/23 11:48:47 [notice] 272#272: signal process started
  nginx: конфиг проверен, reload выполнен
=== Deploy completed at 2026-10-23T11:48:47+00:00 ===

## Диск: крупнейшие каталоги /opt/docker (глубина 2)
435M	/opt/docker/hermes-work/data/lazy-packages
447M	/opt/docker/hermes-work/data/home
1.2G	/opt/docker/hermes-work/
1.2G	/opt/docker/hermes-work/data
1.3G	/opt/docker/hermes/data/workspace
2.1G	/opt/docker/hermes/
2.1G	/opt/docker/hermes/data
3.4G	/opt/docker/hermes-orchestrator/data.backup-2026-10-14/installs
3.4G	/opt/docker/hermes-orchestrator/data/installs
4.0G	/opt/docker/hermes-orchestrator/data.backup-2026-10-14
4.3G	/opt/docker/hermes-orchestrator/data
8.2G	/opt/docker/hermes-orchestrator/

## Диск: крупнейшие файлы больше 100 МБ
144412 KB	/opt/docker/hermes-orchestrator/data.backup-2026-10-14/installs/351f81cc06284494/environments/6a79704cf676407eadf424b08dfe6c1e/workspace/tools/node-26.7.0-linux-x64/bin/node
144412 KB	/opt/docker/hermes-orchestrator/data.backup-2026-10-14/installs/351f81cc06284494/environments/dbb8ea43101448c3b7839067251cea13/workspace/tools/node-26.7.0-linux-x64/bin/node
144412 KB	/opt/docker/hermes-orchestrator/data/installs/351f81cc06284494/environments/602d12975a6a4aa281b230bdcfc67c98/workspace/tools/node-26.7.0-linux-x64/bin/node
144412 KB	/opt/docker/hermes-orchestrator/data/installs/351f81cc06284494/environments/cf4718c02f104ee5a7934aa0ee565925/workspace/tools/node-26.7.0-linux-x64/bin/node
242588 KB	/opt/docker/hermes-orchestrator/data.backup-2026-10-14/installs/351f81cc06284494/environments/6a79704cf676407eadf424b08dfe6c1e/workspace/tools/python-3.14.7+20260901-linux-x64/lib/libpython3.14.so.1.0
242588 KB	/opt/docker/hermes-orchestrator/data.backup-2026-10-14/installs/351f81cc06284494/environments/dbb8ea43101448c3b7839067251cea13/workspace/tools/python-3.14.7+20260901-linux-x64/lib/libpython3.14.so.1.0
242588 KB	/opt/docker/hermes-orchestrator/data/installs/351f81cc06284494/environments/602d12975a6a4aa281b230bdcfc67c98/workspace/tools/python-3.14.7+20260901-linux-x64/lib/libpython3.14.so.1.0
242588 KB	/opt/docker/hermes-orchestrator/data/installs/351f81cc06284494/environments/cf4718c02f104ee5a7934aa0ee565925/workspace/tools/python-3.14.7+20260901-linux-x64/lib/libpython3.14.so.1.0
263456 KB	/opt/docker/hermes-orchestrator/data.backup-2026-10-14/installs/351f81cc06284494/environments/6a79704cf676407eadf424b08dfe6c1e/workspace/tools/chromium-1208/chrome-linux64/chrome
263456 KB	/opt/docker/hermes-orchestrator/data.backup-2026-10-14/installs/351f81cc06284494/environments/dbb8ea43101448c3b7839067251cea13/workspace/tools/chromium-1208/chrome-linux64/chrome
263460 KB	/opt/docker/hermes-orchestrator/data/installs/351f81cc06284494/environments/602d12975a6a4aa281b230bdcfc67c98/workspace/tools/chromium-1208/chrome-linux64/chrome
263460 KB	/opt/docker/hermes-orchestrator/data/installs/351f81cc06284494/environments/cf4718c02f104ee5a7934aa0ee565925/workspace/tools/chromium-1208/chrome-linux64/chrome

## ТРЕВОГИ
нет
