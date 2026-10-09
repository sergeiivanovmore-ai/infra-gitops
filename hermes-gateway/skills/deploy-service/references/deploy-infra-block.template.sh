# Шаблон блока для scripts/deploy-infra.sh.
# Врезать ПОСЛЕ блока reverse-proxy, но ПЕРЕД финальным
#   echo "=== Deploy completed at $(date -Iseconds) ==="
#
# КРИТИЧНО: nginx reload идёт ПОСЛЕДНИМ — после всех docker compose up -d.
# Если reload стоит до старта нового сервиса, nginx -t падает с
# "host not found in upstream". Это воспроизведено в PR #25.
# mkdir -p data-каталога идёт ДО cp compose — иначе cp падает на отсутствии каталога.

# ================================================================
# reverse-proxy (nginx-proxy): конфиги из репо
# ================================================================
mkdir -p /opt/docker/reverse-proxy/conf.d
cp -f "$REPO_DIR/reverse-proxy/conf.d/"*.conf /opt/docker/reverse-proxy/conf.d/
echo "  copied: reverse-proxy/conf.d/*.conf -> /opt/docker/reverse-proxy/conf.d/"
# nginx reload перенесён в конец скрипта — после старта всех сервисов

# ================================================================
# <Service Name>
# ================================================================
mkdir -p /opt/docker/<svc>/data
cp -f "$REPO_DIR/docker/docker-compose.<svc>.yml" /opt/docker/<svc>/docker-compose.yml
echo "  copied: docker-compose.<svc>.yml -> /opt/docker/<svc>/"
# chown -R <uid>:<gid> /opt/docker/<svc>/data  # только если uid образа ≠ 0
cd /opt/docker/<svc> && docker compose up -d

# ================================================================
# nginx reload — ПОСЛЕ старта всех сервисов
# ================================================================
# sleep 5: docker DNS должен успеть зарегистрировать новый сервис в сети,
# иначе nginx -t падает на "host not found in upstream".
sleep 5
docker exec nginx-proxy nginx -t && docker exec nginx-proxy nginx -s reload || echo "  WARN: nginx reload failed"

echo "=== Deploy completed at $(date -Iseconds) ==="

# Замечания:
# - паттерн *.conf намеренно не захватывает мусорные файлы вида <name>.conf.save;
# - при пустом каталоге reverse-proxy/conf.d/ глоб не раскроется и cp упадёт
#   под set -euo pipefail — держать в каталоге хотя бы один conf;
# - живой conf.d прокси смонтирован в контейнер ro, но запись идёт на ХОСТОВУЮ
#   сторону — это допустимо;
# - nginx reload делается ровно ОДИН раз за деплой — в этом финальном блоке.
#   В блоке reverse-proxy reload НЕ дублировать.
