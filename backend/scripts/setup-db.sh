#!/usr/bin/env bash
# Setup local database for System Control Centre
# Creates DB, runs extensions, schema, seeds, and migrations.
# Safe to run multiple times (uses IF NOT EXISTS / ON CONFLICT).

set -euo pipefail

DB_NAME="${SC_DB_NAME:-system_control}"
DB_USER="${SC_DB_USER:-$(whoami)}"
DB_HOST="${SC_DB_HOST:-localhost}"
DB_PORT="${SC_DB_PORT:-5432}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Setting up database: $DB_NAME"
echo "  Host: $DB_HOST:$DB_PORT"
echo "  User: $DB_USER"
echo ""

# Create database if it doesn't exist
if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
  echo "Database '$DB_NAME' already exists"
else
  echo "Creating database '$DB_NAME'..."
  createdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME"
  echo "Created."
fi

PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"

# Step 1: Extensions (pre-init)
echo ""
echo "Running extensions (pre-init)..."
if [ -f "$PROJECT_DIR/dev/sql-seed/pre-init.sql" ]; then
  $PSQL -f "$PROJECT_DIR/dev/sql-seed/pre-init.sql" 2>&1 | grep -v "NOTICE:" || true
fi

# Step 2: Combined schema + seed (new canonical location)
if [ -f "$PROJECT_DIR/dev/sql-seed/system-control-seed.sql" ]; then
  echo "Running combined schema + seed (dev/sql-seed/)..."
  $PSQL -f "$PROJECT_DIR/dev/sql-seed/system-control-seed.sql" 2>&1 | grep -v "NOTICE:" || true
else
  # Fallback: legacy per-file approach from scripts/
  echo "Running autopilot schema..."
  $PSQL -f "$SCRIPT_DIR/autopilot_schema.sql" 2>&1 | grep -v "NOTICE:" || true

  echo "Running RBAC schema..."
  $PSQL -f "$SCRIPT_DIR/rbac_schema.sql" 2>&1 | grep -v "NOTICE:" || true

  echo "Running seed data..."
  $PSQL -f "$SCRIPT_DIR/seed.sql" 2>&1 | grep -v "NOTICE:" || true
fi

# Step 3: Apply migrations in order
MIGRATION_DIR="$PROJECT_DIR/dev/migrations/system-control"
if [ -d "$MIGRATION_DIR" ]; then
  MIGRATIONS=$(find "$MIGRATION_DIR" -name "*.sql" 2>/dev/null | sort)
  if [ -n "$MIGRATIONS" ]; then
    echo ""
    echo "Running migrations..."
    for migration in $MIGRATIONS; do
      migration_name="$(basename "$migration")"
      echo "  Applying: $migration_name"
      $PSQL -f "$migration" 2>&1 | grep -v "NOTICE:" || true
    done
  fi
fi

echo ""
echo "Database ready!"
echo "  Connection: postgres://$DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
echo "  Superadmin: admin@juspay.in / admin123"
