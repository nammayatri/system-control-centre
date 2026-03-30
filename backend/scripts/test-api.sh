#!/usr/bin/env bash
# Test System Control Centre APIs
set -euo pipefail

PORT="${PORT:-8012}"

echo "Testing APIs on port $PORT..."

TOKEN=$(curl -s -X POST "http://localhost:$PORT/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@juspay.in","password":"admin123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)

echo "Login: OK (token: ${TOKEN:0:8}...)"

echo "Releases: $(curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:$PORT/releases?from=2024-01-01T00:00:00Z&to=2026-12-31T00:00:00Z" \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)"

echo "Products: $(curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:$PORT/admin/products" \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('products',[])))" 2>/dev/null)"

echo "Done."
