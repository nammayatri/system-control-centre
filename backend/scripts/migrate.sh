#!/usr/bin/env bash
# Apply SQL migrations in dev/migrations/system-control/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

DB_NAME="${SC_DB_NAME:-system_control}"
DB_USER="${SC_DB_USER:-$(whoami)}"
DB_HOST="${SC_DB_HOST:-localhost}"
DB_PORT="${SC_DB_PORT:-5432}"

MIGRATION_DIR="$PROJECT_DIR/dev/migrations/system-control"

if [ ! -d "$MIGRATION_DIR" ]; then
  echo "Migration directory not found: $MIGRATION_DIR"
  exit 1
fi

MIGRATIONS=$(find "$MIGRATION_DIR" -name "*.sql" 2>/dev/null | sort)

if [ -z "$MIGRATIONS" ]; then
  echo "No migrations to apply."
  exit 0
fi

PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"

echo "Applying migrations..."
for f in $MIGRATIONS; do
  echo "  $(basename "$f")"
  $PSQL -f "$f" 2>&1 | grep -v "NOTICE:" || true
done
echo "Migrations applied."
