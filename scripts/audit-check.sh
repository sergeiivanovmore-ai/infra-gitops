#!/bin/bash
# Проверка: коммит из main, который деплоится, должен приходить из merged PR.
# Режим: AUDIT_MODE=warn|enforce (по умолчанию enforce — «в main только через PR»).
# Аргумент 1 (опционально) — SHA для проверки; по умолчанию origin/main.

AUDIT_MODE="${AUDIT_MODE:-enforce}"
TOKEN_FILE="${TOKEN_FILE:-/root/.github-audit-token}"
REPO="${REPO:-sergeiivanovmore-ai/infra-gitops}"
REPO_DIR="${REPO_DIR:-/opt/infra-gitops}"

if [ ! -f "$TOKEN_FILE" ]; then
  echo "  i  AUDIT skipped: $TOKEN_FILE not found"
  exit 0
fi

TOKEN=$(cat "$TOKEN_FILE")

# Проверяем то, что деплоится: origin/main, а не локальный HEAD.
# На хосте HEAD может стоять на feature-ветке — к деплою это отношения не имеет,
# но именно из-за этого аудит ложно падал при ручном запуске.
SHA="${1:-}"
if [ -z "$SHA" ]; then
  SHA=$(git -C "$REPO_DIR" rev-parse origin/main 2>/dev/null || true)
fi
if [ -z "$SHA" ]; then
  SHA=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
fi
if [ -z "$SHA" ]; then
  echo "  AUDIT: cannot resolve a commit SHA in $REPO_DIR"
  exit 1
fi

RESP=$(curl -s -w '\n%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/commits/$SHA/pulls" 2>/dev/null || true)
CODE=$(printf '%s' "$RESP" | tail -n1)
PR_JSON=$(printf '%s' "$RESP" | sed '$d')

# Отдельный случай: токен нерабочий/просрочен. Раньше это выглядело как
# «коммит не из PR» и блокировало деплой без внятной причины.
if [ "$CODE" != "200" ]; then
  echo "  AUDIT: GitHub API HTTP $CODE — токен аудита нерабочий ($TOKEN_FILE)"
  echo "     аудит не может подтвердить происхождение коммита $SHA"
  if [ "$AUDIT_MODE" = "enforce" ]; then
    exit 1
  fi
  exit 0
fi

if printf '%s' "$PR_JSON" | grep -qE '"merged_at"[[:space:]]*:[[:space:]]*"[^"]+"'; then
  echo "  AUDIT OK: commit $SHA came from a merged PR"
  exit 0
fi

echo "  AUDIT WARN: commit $SHA is NOT from a merged PR"
if [ "$AUDIT_MODE" = "enforce" ]; then
  echo "  AUDIT ENFORCE: blocking deploy — direct pushes to main not allowed"
  exit 1
fi
exit 0