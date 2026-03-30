#!/usr/bin/env bash
# Setup local database for System Control Centre
# Creates DB, runs autopilot schema, RBAC schema, and seeds data.
# Safe to run multiple times (uses IF NOT EXISTS / ON CONFLICT).

set -euo pipefail

DB_NAME="${SC_DB_NAME:-system_control}"
DB_USER="${SC_DB_USER:-$(whoami)}"
DB_HOST="${SC_DB_HOST:-localhost}"
DB_PORT="${SC_DB_PORT:-5432}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Run autopilot schema (release tables)
echo ""
echo "Running autopilot schema..."
$PSQL -f "$SCRIPT_DIR/autopilot_schema.sql" 2>&1 | grep -v "NOTICE:" || true

# Run RBAC schema
echo "Running RBAC schema..."
$PSQL -f "$SCRIPT_DIR/rbac_schema.sql" 2>&1 | grep -v "NOTICE:" || true

# Run seed data
echo "Running seed data..."
$PSQL -f "$SCRIPT_DIR/seed.sql" 2>&1 | grep -v "NOTICE:" || true

echo ""
echo "Database ready!"
echo "  Connection: postgres://$DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
echo "  Superadmin: admin@juspay.in / admin123"
