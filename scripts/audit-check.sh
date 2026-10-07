#!/bin/bash
# Проверка: последний коммит в main должен быть из merged PR.

AUDIT_MODE="${AUDIT_MODE:-warn}"
TOKEN_FILE="/root/.github-audit-token"
REPO="sergeiivanovmore-ai/infra-gitops"

if [ ! -f "$TOKEN_FILE" ]; then
  echo "  ℹ️  AUDIT skipped: $TOKEN_FILE not found"
  exit 0
fi

TOKEN=$(cat "$TOKEN_FILE")
SHA="${1:-$(git -C /opt/infra-gitops rev-parse HEAD)}"

PR_JSON=$(curl -s \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/commits/$SHA/pulls" 2>/dev/null || echo "[]")

# Проверяем "merged_at":"<timestamp>" — надёжнее чем "merged": true,
# потому что GitHub в разных версиях API возвращает одно или другое.
# Также устойчиво к пробелам: "merged_at": "..." или "merged_at":"..."
if echo "$PR_JSON" | grep -qE '"merged_at"[[:space:]]*:[[:space:]]*"[^"]+"'; then
  echo "  ✅ AUDIT OK: commit $SHA came from a merged PR"
  exit 0
fi

echo "  ⚠️  AUDIT WARN: commit $SHA is NOT from a merged PR"
if [ "$AUDIT_MODE" = "enforce" ]; then
  echo "  ❌ AUDIT ENFORCE: blocking deploy — direct pushes to main not allowed"
  exit 1
fi
exit 0
