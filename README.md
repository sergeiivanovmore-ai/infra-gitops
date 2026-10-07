# Infrastructure GitOps

Конфигурация Hermes-агентов и DSH. Изменения — только через Pull Request.

## Структура

- `hermes-gateway/` — оркестратор (Telegram-бот)
- `hermes-sysadmin/` — агент-администратор
- `dsh/` — DeepSeek Harness (профиль web)
- `docker/` — compose-файлы
- `scripts/` — скрипты деплоя
- `.github/workflows/` — CI/CD

## Деплой

Merge PR в `main` → GitHub Actions → SSH на VPS → `deploy-infra.sh`.
# test direct push Wed Oct  7 12:39:02 PM UTC 2026
